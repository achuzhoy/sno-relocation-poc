# Disable built-in rules
MAKEFLAGS += --no-builtin-rules

IMAGE_BASED_DIR = .
SNO_DIR = ./bootstrap-in-place-poc
CONFIG_DIR = ./config-dir

########################

checkenv:
ifndef PULL_SECRET
	$(error PULL_SECRET must be defined)
endif

LIBVIRT_IMAGE_PATH = /var/lib/libvirt/images
BASE_IMAGE_PATH_SNO = $(LIBVIRT_IMAGE_PATH)/sno-test.qcow2
IMAGE_PATH_SNO_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/SNO-baked-image.qcow2
SITE_CONFIG_PATH_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/site-config.iso

MACHINE_NETWORK ?= 192.168.127.0/24
CLUSTER_NAME ?= test-cluster
BASE_DOMAIN ?= redhat.com
HOSTNAME ?= master1

NET_CONFIG_TEMPLATE = $(IMAGE_BASED_DIR)/template-net.xml
NET_CONFIG = $(IMAGE_BASED_DIR)/net.xml

NET_NAME = test-net-2
VM_NAME = sno-test-2
VOL_NAME = $(VM_NAME).qcow2

SSH_KEY_DIR = $(SNO_DIR)/ssh-key
SSH_KEY_PUB_PATH = $(SSH_KEY_DIR)/key.pub
SSH_KEY_PRIV_PATH = $(SSH_KEY_DIR)/key

SSH_FLAGS = -o IdentityFile=$(SSH_KEY_PRIV_PATH) \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no

HOST_IP = 192.168.128.10
SSH_HOST = core@$(HOST_IP)

$(SSH_KEY_DIR):
	@echo Creating SSH key dir
	mkdir $@

$(SSH_KEY_PRIV_PATH): $(SSH_KEY_DIR)
	@echo "No private key $@ found, generating a private-public pair"
	# -N "" means no password
	ssh-keygen -f $@ -N ""
	chmod 400 $@

$(SSH_KEY_PUB_PATH): $(SSH_KEY_PRIV_PATH)

.PHONY: gather checkenv clean destroy-libvirt start-vm network ssh bake wait-for-install-complete $(IMAGE_PATH_SNO_IN_LIBVIRT) $(NET_CONFIG) $(CONFIG_DIR)

.SILENT: destroy-libvirt

### Install SNO from ISO
start-iso: bootstrap-in-place-poc
	make -C $(SNO_DIR) $@

start-iso-abi: bootstrap-in-place-poc machineConfigs/internal-ip.yaml
	@echo "Add the internal-ip machine config - this is required until https://github.com/openshift/machine-config-operator/pull/3774 is merged"
	cp machineConfigs/internal-ip.yaml $(SNO_DIR)/manifests/
	@echo "Replace the bootstrap-in-place agent-config.yaml with the config from this repo"
	cp agent-config.yaml $(SNO_DIR)
	MACHINE_NETWORK=${MACHINE_NETWORK} make -C $(SNO_DIR) $@

bootstrap-in-place-poc:
	rm -rf $(SNO_DIR)
	git clone https://github.com/eranco74/bootstrap-in-place-poc

wait-for-install-complete:
	echo "Waiting for installation to complete"
	until [ "$$(oc get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo "Still waiting for installation to complete ..."; \
			sleep 10; \
	done

### Bake the image template

bake: machineConfigs
	oc --kubeconfig $(SNO_DIR)/sno-workdir/auth/kubeconfig apply -f ./machineConfigs/installation-configuration.yaml
	oc --kubeconfig $(SNO_DIR)/sno-workdir/auth/kubeconfig apply -f ./machineConfigs/dnsmasq.yaml
	echo "Wait for mcp to update, the node will reboot in the process"
	sleep 120
	oc --kubeconfig $(SNO_DIR)/sno-workdir/auth/kubeconfig wait --timeout=20m --for=condition=updated=true mcp master

	# TODO: add this once we have the bootstrap script
	make -C $(SNO_DIR) ssh CMD="sudo systemctl disable kubelet"
	make -C $(SNO_DIR) ssh CMD="sudo shutdown"
	# for some reason the libvirt VM stay running, wait 60 seconds and destroy it
	sleep 60 && sudo virsh destroy sno-test
	make wait-for-shutdown
	sudo virsh undefine sno-test

machineConfigs: machineConfigs/installation-configuration.yaml machineConfigs/dnsmasq.yaml

# Generate installation-configuration machine config that will create the service that reconfigure the node.
machineConfigs/installation-configuration.yaml: bake/installation-configuration.sh butane-installation-configuration.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-installation-configuration.yaml > $@ || (rm $@ && false)

machineConfigs/dnsmasq.yaml: bake/dnsmasq.conf bake/force-dns-script bake/unmanaged-resolv.conf butane-dnsmasq.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-dnsmasq.yaml > $@ || (rm $@ && false)

machineConfigs/internal-ip.yaml: bake/dispatcher-pre-up-internal-ip.sh bake/crio-nodenet.conf bake/kubelet-nodenet.conf
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-internal-ip.yaml > $@ || (rm $@ && false)


wait-for-shutdown:
	until sudo virsh domstate sno-test | grep shut; do \
  		echo " sno-test still running"; \
  		sleep 10; \
    done

### Create new image from template
create-image-template: $(IMAGE_PATH_SNO_IN_LIBVIRT)

$(IMAGE_PATH_SNO_IN_LIBVIRT): $(BASE_IMAGE_PATH_SNO)
	sudo mv $< $@
	sudo chown qemu:qemu $@

### Create a new SNO from the image template

# Render the libvirt net config file with the network name and host IP
$(NET_CONFIG): $(NET_CONFIG_TEMPLATE)
	sed -e 's/REPLACE_NET_NAME/$(NET_NAME)/' \
		-e 's/REPLACE_HOST_IP/$(HOST_IP)/' \
		-e 's|CLUSTER_NAME|$(CLUSTER_NAME)|' \
		-e 's|BASE_DOMAIN|$(BASE_DOMAIN)|' \
		-e 's|HOSTNAME|$(HOSTNAME)|' \
	    $(NET_CONFIG_TEMPLATE) > $@
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		sed -i "/dhcp/,/\/dhcp/d" $@; \
	fi

network: destroy-libvirt $(NET_CONFIG)
	NET_XML=$(NET_CONFIG) \
	HOST_IP=$(HOST_IP) \
	CLUSTER_NAME=$(CLUSTER_NAME) \
	BASE_DOMAIN=$(BASE_DOMAIN) \
	HOSTNAME=$(HOSTNAME) \
	$(SNO_DIR)/virt-create-net.sh

# Destroy previously created VMs/Networks and create a VM/Network with the pre-baked image
start-vm: checkenv $(IMAGE_PATH_SNO_IN_LIBVIRT) network $(SITE_CONFIG_PATH_IN_LIBVIRT)
	IMAGE=$(IMAGE_PATH_SNO_IN_LIBVIRT) \
	VM_NAME=$(VM_NAME) \
	NET_NAME=$(NET_NAME) \
	SITE_CONFIG=$(SITE_CONFIG_PATH_IN_LIBVIRT) \
	$(IMAGE_BASED_DIR)/virt-install-sno.sh


# Set the network name to static and call start-vm
start-vm-static-network: STATIC_NETWORK = "TRUE"
start-vm-static-network: start-vm

ssh: $(SSH_KEY_PRIV_PATH)
	ssh $(SSH_FLAGS) $(SSH_HOST)

$(CONFIG_DIR):
	rm -rf $@
	mkdir -p $@

$(CONFIG_DIR)/site-config.env: $(CONFIG_DIR) checkenv
	echo CLUSTER_NAME=${CLUSTER_NAME} > $@
	echo BASE_DOMAIN=${BASE_DOMAIN} >> $@
	echo -n PULL_SECRET= >> $@
	echo -n "'" >> $@
	echo -n "$${PULL_SECRET}" >> $@
	echo -n "'" >> $@

site-config.iso: $(CONFIG_DIR)/site-config.env
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		echo "Adding static network configuration to ISO"; \
		cp static_network.cfg $(CONFIG_DIR)/enp1s0.nmconnection; \
	fi
	mkisofs -o site-config.iso -R -V "ZTC SNO" $(CONFIG_DIR)

$(SITE_CONFIG_PATH_IN_LIBVIRT): site-config.iso
	sudo cp site-config.iso $(LIBVIRT_IMAGE_PATH)
	sudo chown qemu:qemu $(LIBVIRT_IMAGE_PATH)/site-config.iso
	sudo restorecon $(LIBVIRT_IMAGE_PATH)/site-config.iso

update_script:
	cat bake/installation-configuration.sh | ssh $(SSH_FLAGS) $(SSH_HOST) "sudo tee /usr/local/bin/installation-configuration.sh"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl daemon-reload"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl restart installation-configuration.service --no-block"

### Cleanup

destroy-libvirt:
	echo "Destroying previous libvirt resources"
	NET_NAME=$(NET_NAME) \
        VM_NAME=$(VM_NAME) \
        VOL_NAME=$(VOL_NAME) \
	$(SNO_DIR)/virt-delete-sno.sh || true


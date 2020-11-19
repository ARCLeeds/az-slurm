#!/bin/sh

set -x
exec >& /root/azuredeploy.log.$$

SLURMVERSION=20.02.6

# This script can be found on https://raw.githubusercontent.com/ARCLeeds/az-slurm/main/CentOS/azuredeploy.sh
# This script is part of azure deploy ARM template
# This script will install SLURM on a Linux cluster deployed on a set of Azure VMs

# Basic info
env
date
whoami
echo $@

# Usage
if [ "$#" -ne 13 ]; then
  echo "$#: $0 $*"
  echo "Usage: $0 MASTER_NAME MASTER_IP WORKER_NAME WORKER_IP_BASE WORKER_IP_START NUM_OF_VM ADMIN_USERNAME ADMIN_PASSWORD TEMPLATE_BASE RG_NAME TENANT_ID SP_ID SP_SECRET"
  exit 1
fi

# Preparation steps - hosts and ssh
###################################

# Parameters
MASTER_NAME=$1
MASTER_IP=$2
WORKER_NAME=$3
WORKER_IP_BASE=$4
WORKER_IP_START=$5
NUM_OF_VM=$6
ADMIN_USERNAME=$7
ADMIN_PASSWORD=$8
TEMPLATE_BASE=$9
RG_NAME=${10}
TENANT_ID=${11}
SP_ID=${12}
SP_SECRET=${13}

ssh_known_hosts=/tmp/ssh_known_hosts.$$
shosts_equiv=/tmp/shosts.equiv.$$

# Install AZ CLI
rpm --import https://packages.microsoft.com/keys/microsoft.asc
sh -c 'echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'

yum -y install azure-cli

# Update sudo rule for azureuser
sed -i -- 's/azureuser ALL=(ALL) ALL/azureuser ALL=(ALL) NOPASSWD:ALL/g' /etc/sudoers.d/waagent

# Update master node
echo "* soft memlock unlimited" >> /etc/security/limits.conf
echo "* hard memlock unlimited" >> /etc/security/limits.conf

# Update ssh config file to ignore unknown host
# Note all settings are for azureuser, NOT root
sudo -u $ADMIN_USERNAME sh -c "mkdir /home/$ADMIN_USERNAME/.ssh/;echo Host worker\* > /home/$ADMIN_USERNAME/.ssh/config; echo StrictHostKeyChecking no >> /home/$ADMIN_USERNAME/.ssh/config; echo UserKnownHostsFile=/dev/null >> /home/$ADMIN_USERNAME/.ssh/config"

# Generate a set of sshkey under /home/azureuser/.ssh if there is not one yet
if ! [ -f /home/$ADMIN_USERNAME/.ssh/id_rsa ]; then
    sudo -u $ADMIN_USERNAME sh -c "ssh-keygen -f /home/$ADMIN_USERNAME/.ssh/id_rsa -t rsa -N ''"
fi

# Generate a root ssh key
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''

# Enable EPEL
yum -y install epel-release

yum -y install python3

# Install sshpass to automate ssh-copy-id action
yum install -y sshpass

# Install ansible and start the ansible hosts file
yum -y install ansible
echo "[master]" > /etc/ansible/hosts
echo $MASTER_NAME >> /etc/ansible/hosts
echo "[workers]" >> /etc/ansible/hosts

# Install software needed for NFS server
yum -y install nfs-utils libnfsidmap
systemctl enable rpcbind
systemctl enable nfs-server
systemctl start rpcbind
systemctl start nfs-server
systemctl start rpc-statd
systemctl start nfs-idmapd

# Configure data disks and export via an NFS share
DATADISKS=/dev/disk/azure/scsi1/*

pvcreate $DATADISKS
vgcreate vg_data $DATADISKS
lvcreate -n lv_data -l 100%FREE vg_data
mkfs.xfs /dev/vg_data/lv_data
mkdir /data
echo -e "/dev/mapper/vg_data-lv_data\t/data\txfs\tdefaults\t0 0" >> /etc/fstab
mount /data
chmod 1777 /data
mkdir /data/home
mv /home/* /data/home/
echo -e "/data/home\t/home\tnone\tbind\t0 0" >> /etc/fstab
mount /home
restorecon /home

echo "/data *(rw,sync,no_root_squash)" > /etc/exports
exportfs -a

# Start building needed SSH files used for host authentication
/usr/bin/ssh-keyscan master > /tmp/ssh-template
cat /tmp/ssh-template >> $ssh_known_hosts
sed "s/master/master,master.internal.cloudapp.net/" /tmp/ssh-template >> $ssh_known_hosts
echo master > $shosts_equiv
echo master.internal.cloudapp.net >> $shosts_equiv
echo master.internal.cloudapp.net,master 10.0.0.254 >> /etc/hosts

install -m 600 -o $ADMIN_USERNAME -g $ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh/id_rsa.pub /home/$ADMIN_USERNAME/.ssh/authorized_keys

# Loop through all worker nodes, update hosts file and copy ssh public key to it
# The script make the assumption that the node is called %WORKER+<index> and have
# static IP in sequence order
i=0
while [ $i -lt $NUM_OF_VM ]
do
   worker=$WORKER_NAME$i
   workerip=`expr $i + $WORKER_IP_START`
   echo 'I update host - '$WORKER_NAME$i
   sudo -u $ADMIN_USERNAME sh -c "sshpass -p '$ADMIN_PASSWORD' ssh-copy-id $WORKER_NAME$i"
   sed
   sed "s/master/$WORKER_IP_BASE$workerip/" /tmp/ssh-template >> $ssh_known_hosts
   sed "s/master/$worker,$worker.internal.cloudapp.net/" /tmp/ssh-template >> $ssh_known_hosts
   echo $worker >> $shosts_equiv
   echo $WORKER_NAME$i >> /etc/ansible/hosts
   echo $WORKER_IP_BASE$workerip $worker.internal.cloudapp.net,$worker >> /etc/hosts
   i=`expr $i + 1`
done

# Install the Development Tools
yum -y groupinstall "Development Tools"
yum -y install rpm-build

# Build SLURM on master node
###################################

wget https://download.schedmd.com/slurm/slurm-${SLURMVERSION}.tar.bz2
yum install -y hwloc-devel hwloc-libs hdf5-devel munge munge-devel munge-libs numactl-devel numactl-libs readline-devel openssl-devel pam-devel perl-ExtUtils-MakeMaker mariadb-devel
rpmbuild -ta slurm-${SLURMVERSION}.tar.bz2

# Generate the munge key
echo "Generating munge key"
umask 0077
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
umask 0022

# Create the slurm user
useradd -c "Slurm scheduler" slurm

cat > test.out <<EOB
#!/bin/bash

exec >> /home/slurm/slurm.log

echo Called: \$0 \$*

~/az-login

HOSTS=\$(scontrol show hostnames \$1)

for host in \$HOSTS;do
  echo \$host Starting
  az vm start --name \$host --resource-group $RG_NAME --no-wait
  echo \$host Started
done

for host in \$HOSTS;do
  echo -n \$host Probing
  for i in {1..1000}; do
    echo -n .
    ssh -o ConnectTimeout=5 \$host 'netstat -nl|grep 6818 >& /dev/null' && echo Done && break
    sleep 1
  done
done

exit 0
EOB

cat > /home/slurm/slurm-suspend <<EOB
#!/bin/bash

exec >> /home/slurm/slurm.log

echo Called: \$0 \$*

~/az-login

HOSTS=\$(scontrol show hostnames \$1)

for host in \$HOSTS;do
  echo \$host Deallocating
  az vm deallocate --name \$host --resource-group $RG_NAME
  echo \$host Deallocated
done
EOB

cat > /home/slurm/az-login <<EOB
#!/bin/bash
az login --service-principal -u $SP_ID -p $SP_SECRET --tenant $TENANT_ID
EOB

chmod 755 /home/slurm/slurm-suspend /home/slurm/slurm-resume /home/slurm/az-login

# Install the packages needed on the master
yum -y install /rpmbuild/RPMS/x86_64/slurm-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-contribs-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-example-configs-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-pam_slurm-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-perlapi-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-libpmi-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-slurmctld-${SLURMVERSION}-1.el7.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-slurmdbd-${SLURMVERSION}-1.el7.x86_64.rpm

# Download slurm.conf and fill in the node info
SLURMCONF=/tmp/slurm.conf.$$
wget $TEMPLATE_BASE/slurm.template.conf -O $SLURMCONF
sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $SLURMCONF
lastvm=`expr $NUM_OF_VM - 1`
sed -i -- 's/__WORKERNODES__/'"$WORKER_NAME"'[0-'"$lastvm"']/g' $SLURMCONF
cp -f $SLURMCONF /etc/slurm/slurm.conf
chown slurm /etc/slurm/slurm.conf
mkdir /var/spool/slurmd
chown slurm:slurm /var/spool/slurmd
systemctl daemon-reload
systemctl enable munge
systemctl start munge # Start munged
systemctl enable slurmctld
systemctl start  slurmctld # Start the master daemon service

# Set up the Ansible playbook that can build the /etc/slurm/slurm.conf file
PLAYBOOK=/tmp/create_slurm_conf.yml.$$
wget $TEMPLATE_BASE/create_slurm_conf.yml -O $PLAYBOOK
sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $PLAYBOOK
cp -f $PLAYBOOK /home/$ADMIN_USERNAME/create_slurm_conf.yml
chown $ADMIN_USERNAME /home/$ADMIN_USERNAME/create_slurm_conf.yml
SLURMJ2=/tmp/slurm_conf.j2.$$
wget $TEMPLATE_BASE/slurm_conf.j2 -O $SLURMJ2
cp -f $SLURMJ2 /home/$ADMIN_USERNAME/slurm_conf.j2
chown $ADMIN_USERNAME /home/slurm_conf.j2

# Download the SSH configuration files
SSHDCONFIG=/tmp/sshd_config.$$
wget $TEMPLATE_BASE/sshd_config -O $SSHDCONFIG
SSHCONFIG=/tmp/ssh_config.$$
wget $TEMPLATE_BASE/ssh_config -O $SSHCONFIG

# Prep shared files
mkdir -m 711 /data/system

# Update slurm.conf with the number of CPUs detected on the compute nodes
# sudo -iu $ADMIN_USERNAME /usr/bin/ansible-playbook create_slurm_conf.yml
# scontrol reconfigure

cp $ssh_known_hosts /etc/ssh/ssh_known_hosts
cp $shosts_equiv /etc/ssh/shosts.equiv
cp $SSHDCONFIG /etc/ssh/sshd_config
cp $SSHCONFIG /etc/ssh/ssh_config
systemctl restart sshd

yum -y install openmpi3-devel

# This should be removed and fixed
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/sysconfig/selinux

# Make sudo passwordless for AAD Admins
echo '%aad_admins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aad_admins

cp /etc/hosts /data/system/
cp -a /root/.ssh/id_ed25519.pub /data/system/authorized_keys
cp -a /rpmbuild/RPMS /data/system
cp /etc/munge/munge.key /data/system
mv /etc/slurm/slurm.conf /data/system
ln -s /data/system/slurm.conf /etc/slurm/slurm.conf
mkdir /data/system/ssh
cp -a /etc/ssh/s* /data/system/ssh/

cat > /etc/cron.d/sync-aadpasswd <<EOB
* * * * * root rsync -a /etc/aadpasswd /data/system/aadpasswd
EOB

exit 0

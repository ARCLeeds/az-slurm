#!/bin/sh

# This script can be found on https://gitlab.oit.duke.edu/OIT-DCC/Azure-Slurm/CentOS/azuredeploy.sh
# This script is part of azure deploy ARM template
# This script will install SLURM on a Linux cluster deployed on a set of Azure VMs

# Basic info
date > /tmp/azuredeploy.log.$$ 2>&1
whoami >> /tmp/azuredeploy.log.$$ 2>&1
echo $@ >> /tmp/azuredeploy.log.$$ 2>&1

# Usage
if [ "$#" -ne 9 ]; then
  echo "Usage: $0 MASTER_NAME MASTER_IP WORKER_NAME WORKER_IP_BASE WORKER_IP_START NUM_OF_VM ADMIN_USERNAME ADMIN_PASSWORD TEMPLATE_BASE" >> /tmp/azuredeploy.log.$$
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

# Update sudo rule for azureuser
sudo sed -i -- 's/azureuser ALL=(ALL) ALL/azureuser ALL=(ALL) NOPASSWD:ALL/g' /etc/sudoers.d/waagent >> /tmp/azuredeploy.log.$$ 2>&1

# Update master node
echo $MASTER_IP $MASTER_NAME >> /etc/hosts
echo $MASTER_IP $MASTER_NAME > /tmp/hosts.$$
sudo echo "* soft memlock unlimited" >> /etc/security/limits.conf
sudo echo "* hard memlock unlimited" >> /etc/security/limits.conf

# Update ssh config file to ignore unknown host
# Note all settings are for azureuser, NOT root
sudo -u $ADMIN_USERNAME sh -c "mkdir /home/$ADMIN_USERNAME/.ssh/;echo Host worker\* > /home/$ADMIN_USERNAME/.ssh/config; echo StrictHostKeyChecking no >> /home/$ADMIN_USERNAME/.ssh/config; echo UserKnownHostsFile=/dev/null >> /home/$ADMIN_USERNAME/.ssh/config"

# Generate a set of sshkey under /home/azureuser/.ssh if there is not one yet
if ! [ -f /home/$ADMIN_USERNAME/.ssh/id_rsa ]; then
    sudo -u $ADMIN_USERNAME sh -c "ssh-keygen -f /home/$ADMIN_USERNAME/.ssh/id_rsa -t rsa -N ''"
fi

# Enable EPEL
sudo yum -y install epel-release

# Install sshpass to automate ssh-copy-id action
sudo yum install -y sshpass >> /tmp/azuredeploy.log.$$ 2>&1

# Install ansible and start the ansible hosts file
sudo yum -y install ansible >> /tmp/azuredeploy.log.$$ 2>&1
sudo echo "[master]" > /etc/ansible/hosts
sudo echo $MASTER_NAME >> /etc/ansible/hosts
sudo echo "[workers]" >> /etc/ansible/hosts

# Install software needed for NFS server
sudo yum -y install nfs-utils libnfsidmap >> /tmp/azuredeploy.log.$$ 2>&1
sudo systemctl enable rpcbind
sudo systemctl enable nfs-server
sudo systemctl start rpcbind
sudo systemctl start nfs-server
sudo systemctl start rpc-statd
sudo systemctl start nfs-idmapd

# Configure data disks and export via an NFS share
DATADISKS="$(lsblk -dlnpo name | grep -v -E 'sda|sdb|fd0|sr0')"

sudo pvcreate $DATADISKS >> /tmp/azuredeploy.log.$$ 2>&1
sudo vgcreate vg_data $DATADISKS >> /tmp/azuredeploy.log.$$ 2>&1
sudo lvcreate -n lv_data -l 100%FREE vg_data >> /tmp/azuredeploy.log.$$ 2>&1
sudo mkfs.xfs /dev/vg_data/lv_data >> /tmp/azuredeploy.log.$$ 2>&1
sudo mkdir /data
sudo echo -e "/dev/mapper/vg_data-lv_data\t/data\txfs\tdefaults\t0 0" >> /etc/fstab
sudo mount /data
sudo chmod 777 /data

sudo echo "/data *(rw,sync,no_root_squash)" > /etc/exports
sudo exportfs -a


# Loop through all worker nodes, update hosts file and copy ssh public key to it
# The script make the assumption that the node is called %WORKER+<index> and have
# static IP in sequence order
i=0
while [ $i -lt $NUM_OF_VM ]
do
   workerip=`expr $i + $WORKER_IP_START`
   echo 'I update host - '$WORKER_NAME$i >> /tmp/azuredeploy.log.$$ 2>&1
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> /etc/hosts
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> /tmp/hosts.$$
   sudo -u $ADMIN_USERNAME sh -c "sshpass -p '$ADMIN_PASSWORD' ssh-copy-id $WORKER_NAME$i"
   sudo echo $WORKER_NAME$i >> /etc/ansible/hosts
   i=`expr $i + 1`
done

# Install the Development Tools
sudo yum -y groupinstall "Development Tools"
sudo yum -y install rpm-build

# Build SLURM on master node
###################################

wget https://download.schedmd.com/slurm/slurm-17.11.8.tar.bz2 >> /tmp/azuredeploy.log.$$ 2>&1
sudo yum install -y hwloc-devel hwloc-libs hdf5-devel munge munge-devel munge-libs numactl-devel numactl-libs readline-devel openssl-devel pam-devel perl-ExtUtils-MakeMaker mariadb-devel >> /tmp/azuredeploy.log.$$ 2>&1
rpmbuild -ta slurm-17.11.8.tar.bz2 >> /tmp/azuredeploy.log.$$ 2>&1

# Generate the munge key
echo "Generating munge key" >> /tmp/azuredeploy.log.$$ 2>&1
dd if=/dev/urandom bs=1 count=1024 >/tmp/munge.key
sudo chown munge:munge /tmp/munge.key
sudo chmod 600 /tmp/munge.key
sudo mv /tmp/munge.key /etc/munge/munge.key

# Create the slurm user
sudo useradd -c "Slurm scheduler" slurm

# Install the packages needed on the master
sudo yum -y install /rpmbuild/RPMS/x86_64/slurm-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-contribs-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-example-configs-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-pam_slurm-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-perlapi-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-libpmi-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-slurmctld-17.11.8-1.el7.centos.x86_64.rpm \
/rpmbuild/RPMS/x86_64/slurm-slurmdbd-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1

# Download slurm.conf and fill in the node info
SLURMCONF=/tmp/slurm.conf.$$
wget $TEMPLATE_BASE/slurm.template.conf -O $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1
sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1
lastvm=`expr $NUM_OF_VM - 1`
sed -i -- 's/__WORKERNODES__/'"$WORKER_NAME"'[0-'"$lastvm"']/g' $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1
sudo cp -f $SLURMCONF /etc/slurm/slurm.conf >> /tmp/azuredeploy.log.$$ 2>&1
sudo chown slurm /etc/slurm/slurm.conf >> /tmp/azuredeploy.log.$$ 2>&1
sudo chmod o+w /var/spool # Write access for slurmctld log. Consider switch log file to another location
sudo systemctl daemon-reload >> /tmp/azuredeploy.log.$$ 2>&1
sudo systemctl enable munge >> /tmp/azuredeploy.log.$$ 2>&1
sudo systemctl start munge >> /tmp/azuredeploy.log.$$ 2>&1 # Start munged
sudo systemctl enable slurmctld >> /tmp/azuredeploy.log.$$ 2>&1
sudo systemctl start  slurmctld >> /tmp/azuredeploy.log.$$ 2>&1 # Start the master daemon service

# Set up the Ansible playbook that can build the /etc/slurm/slurm.conf file
PLAYBOOK=/tmp/create_slurm_conf.yml.$$
wget $TEMPLATE_BASE/create_slurm_conf.yml -O $PLAYBOOK >> /tmp/azuredeploy.log.$$ 2>&1
sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $PLAYBOOK >> /tmp/azuredeploy.log.$$ 2>&1
cp -f $PLAYBOOK /home/$ADMIN_USERNAME/create_slurm_conf.yml
sudo chown $ADMIN_USERNAME /home/$ADMIN_USERNAME/create_slurm_conf.yml
SLURMJ2=/tmp/slurm_conf.j2.$$
wget $TEMPLATE_BASE/slurm_conf.j2 -O $SLURMJ2 >> /tmp/azuredeploy.log.$$ 2>&1
cp -f $SLURMJ2 /home/$ADMIN_USERNAME/slurm_conf.j2
sudo chown $ADMIN_USERNAME /home/slurm_conf.j2

# Download worker_config.sh and add admin password for sudo
WORKERCONFIG=/tmp/worker_config.sh.$$
wget $TEMPLATE_BASE/worker_config.sh -O $WORKERCONFIG >> /tmp/azuredeploy.log.$$ 2>&1
sed -i -- 's/__ADMINPASS__/'"$ADMIN_PASSWORD"'/g' $WORKERCONFIG >> /tmp/azuredeploy.log.$$ 2>&1

# Download the scripts to create users
READCSV=/tmp/user_read_csv_create_yml.py.$$
wget $TEMPLATE_BASE/user_read_csv_create_yml.py -O $READCSV >> /tmp/azuredeploy.log.$$ 2>&1
cp -f $READCSV /home/$ADMIN_USERNAME/user_read_csv_create_yml.py
sudo chown $ADMIN_USERNAME /home/$ADMIN_USERNAME/user_read_csv_create_yml.py
CREATEUSERS=/tmp/create_users.yml.$$
wget $TEMPLATE_BASE/create_users.yml -O $CREATEUSERS >> /tmp/azuredeploy.log.$$ 2>&1
cp -f $CREATEUSERS /home/$ADMIN_USERNAME/create_users.yml
sudo chown $ADMIN_USERNAME /home/$ADMIN_USERNAME/create_users.yml

# Download the SSH configuration files
SSHDCONFIG=/tmp/sshd_config.$$
wget $TEMPLATE_BASE/sshd_config -O $SSHDCONFIG >> /tmp/azuredeploy.log.$$ 2>&1
SSHCONFIG=/tmp/ssh_config.$$
wget $TEMPLATE_BASE/ssh_config -O $SSHCONFIG >> /tmp/azuredeploy.log.$$ 2>&1

# Start building needed SSH files used for host authentication
ssh_known_hosts=/tmp/ssh_known_hosts.$$
/usr/bin/ssh-keyscan master > $ssh_known_hosts
shosts_equiv=/tmp/shosts.equiv.$$
echo 'master' > $shosts_equiv

# Install slurm on all nodes
# Also push munge key and slurm.conf to them
echo "Prepare the local copy of munge key" >> /tmp/azuredeploy.log.$$ 2>&1 

mungekey=/tmp/munge.key.$$
sudo cp -f /etc/munge/munge.key $mungekey
sudo chown $ADMIN_USERNAME $mungekey

echo "Start looping all workers" >> /tmp/azuredeploy.log.$$ 2>&1 
shosts.equiv
i=0
while [ $i -lt $NUM_OF_VM ]
do
   worker=$WORKER_NAME$i

   echo "SCP to $worker"  >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $mungekey $ADMIN_USERNAME@$worker:/tmp/munge.key >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $SLURMCONF $ADMIN_USERNAME@$worker:/tmp/slurm.conf >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp $WORKERCONFIG $ADMIN_USERNAME@$worker:/tmp/worker_config.sh >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /tmp/hosts.$$ $ADMIN_USERNAME@$worker:/tmp/hosts >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-contribs-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-contribs-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-example-configs-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-example-configs-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-libpmi-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-libpmi-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-pam_slurm-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-pam_slurm-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME scp /rpmbuild/RPMS/x86_64/slurm-slurmd-17.11.8-1.el7.centos.x86_64.rpm $ADMIN_USERNAME@$worker:/tmp/slurm-slurmd-17.11.8-1.el7.centos.x86_64.rpm >> /tmp/azuredeploy.log.$$ 2>&1

   echo "Remote execute on $worker" >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sh /tmp/worker_config.sh' >> /tmp/azuredeploy.log.$$ 2>&1

   # While we're looping through all the workers grab the ssh host keys for each to deploy ssh_known_hosts afterwards
   /usr/bin/ssh-keyscan $worker >> $ssh_known_hosts
   echo $worker >> $shosts_equiv

   i=`expr $i + 1`
done
rm -f $mungekey

# Update slurm.conf with the number of CPUs detected on the compute nodes
/usr/bin/ansible-playbook create_slurm_conf.yml
sudo systemctl restart slurmctld
sudo scontrol reconfigure

# Configure ssh for host based authentication
i=0
while [ $i -lt $NUM_OF_VM ]
do
   worker=$WORKER_NAME$i

   echo "SCP to $worker"  >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $ssh_known_hosts $ADMIN_USERNAME@$worker:/tmp/ssh_known_hosts >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $shosts_equiv $ADMIN_USERNAME@$worker:/tmp/shosts.equiv >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $SSHDCONFIG $ADMIN_USERNAME@$worker:/tmp/sshd_config >> /tmp/azuredeploy.log.$$ 2>&1 
   sudo -u $ADMIN_USERNAME scp $SSHCONFIG $ADMIN_USERNAME@$worker:/tmp/ssh_config >> /tmp/azuredeploy.log.$$ 2>&1 

   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sudo cp /tmp/ssh_known_hosts /etc/ssh/ssh_known_hosts' >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sudo cp /tmp/shosts.equiv /etc/ssh/shosts.equiv' >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sudo cp /tmp/sshd_config /etc/ssh/sshd_config' >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sudo cp /tmp/ssh_config /etc/ssh/ssh_config' >> /tmp/azuredeploy.log.$$ 2>&1
   sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker 'sudo systemctl restart sshd' >> /tmp/azuredeploy.log.$$ 2>&1

   i=`expr $i + 1`
done

sudo cp $ssh_known_hosts /etc/ssh/ssh_known_hosts
sudo cp $shosts_equiv /etc/ssh/shosts.equiv
sudo cp $SSHDCONFIG /etc/ssh/sshd_config
sudo cp $SSHCONFIG /etc/ssh/ssh_config
sudo systemctl restart sshd

exit 0

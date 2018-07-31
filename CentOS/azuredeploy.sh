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

# Update master node
echo $MASTER_IP $MASTER_NAME >> /etc/hosts
echo $MASTER_IP $MASTER_NAME > /tmp/hosts.$$

# Update ssh config file to ignore unknow host
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

# Download worker_config.sh and add admin password for sudo
WORKERCONFIG=/tmp/worker_config.sh.$$
wget $TEMPLATE_BASE/worker_config.sh -O $WORKERCONFIG >> /tmp/azuredeploy.log.$$ 2>&1
sed -i -- 's/__ADMINPASS__/'"$ADMIN_PASSWORD"'/g' $WORKERCONFIG >> /tmp/azuredeploy.log.$$ 2>&1

# Install slurm on all nodes by running apt-get
# Also push munge key and slurm.conf to them
echo "Prepare the local copy of munge key" >> /tmp/azuredeploy.log.$$ 2>&1 

mungekey=/tmp/munge.key.$$
sudo cp -f /etc/munge/munge.key $mungekey
sudo chown $ADMIN_USERNAME $mungekey

echo "Start looping all workers" >> /tmp/azuredeploy.log.$$ 2>&1 

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

   i=`expr $i + 1`
done
rm -f $mungekey

# Restart slurm service on all nodes

exit 0

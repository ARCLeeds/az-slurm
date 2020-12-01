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
  echo "Usage: $0 MASTER_NAME MASTER_IP WORKER_IP_BASE WORKER_IP_START ADMIN_USERNAME ADMIN_PASSWORD TEMPLATE_BASE RG_NAME TENANT_ID SP_ID SP_SECRET PARTITIONS EXTRASLURM"
  exit 1
fi

# Preparation steps - hosts and ssh
###################################

# Parameters
MASTER_NAME=$1
MASTER_IP=$2
WORKER_IP_BASE=$3
WORKER_IP_START=$4
ADMIN_USERNAME=$5
ADMIN_PASSWORD=$6
TEMPLATE_BASE=$7
RG_NAME=$8
TENANT_ID=$9
SP_ID=${10}
SP_SECRET=${11}
BASE64_ENCODED=${12}
EXTRASLURM=$(echo ${13} | base64 --decode)

ssh_known_hosts=/tmp/ssh_known_hosts.$$
shosts_equiv=/tmp/shosts.equiv.$$

# Enable EPEL and get a JSON parser
yum -y install epel-release
yum -y install jq

JSON=$(echo $BASE64_ENCODED | base64 --decode)

PARTITION_COUNT=$(echo $JSON | jq -r '. | length')

echo $PARTITION_COUNT

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
if [[ ! -f /root/.ssh/id_ed25519 ]] ; then
  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''
fi

yum -y install python3

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
chmod 0755 /data
mkdir /data/home
mv /home/* /data/home/
echo -e "/data/home\t/home\tnone\tx-systemd.requires=/data,bind\t0 0" >> /etc/fstab
mount /home
restorecon /home
# Prep shared files
mkdir -m 711 /data/system

cat > /etc/exports <<EOB
/data *(rw,sync,no_root_squash)
/opt  *(rw,sync,no_root_squash)
EOB

exportfs -a

# Start building needed SSH files used for host authentication
/usr/bin/ssh-keyscan master > /tmp/ssh-template
sed "s/master/master,master.internal.cloudapp.net/" /tmp/ssh-template >> $ssh_known_hosts
echo master > $shosts_equiv
echo master.internal.cloudapp.net >> $shosts_equiv
echo 10.0.0.254 master.internal.cloudapp.net master >> /etc/hosts

install -m 600 -o $ADMIN_USERNAME -g $ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh/id_rsa.pub /home/$ADMIN_USERNAME/.ssh/authorized_keys

# Install the Development Tools
yum -y groupinstall "Development Tools"
yum -y install rpm-build

# Build SLURM on master node
###################################

yum install -y hwloc-devel hwloc-libs hdf5-devel munge munge-devel munge-libs numactl-devel numactl-libs readline-devel openssl-devel pam-devel perl-ExtUtils-MakeMaker mariadb-devel
cd /tmp
curl https://download.schedmd.com/slurm/slurm-${SLURMVERSION}.tar.bz2 | tar xj
cd slurm-${SLURMVERSION}
./configure --prefix=/opt/slurm
make
make install
cd -

cat > /etc/systemd/system/slurmctld.service <<'EOB'
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
ConditionPathExists=/opt/slurm/etc/slurm.conf

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmctld
ExecStart=/opt/slurm/sbin/slurmctld $SLURMCTLD_OPTIONS
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/var/run/slurmd.pid
KillMode=process
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOB

cat > /etc/profile.d/slurm.sh <<EOB
export PATH=/opt/slurm/bin:$PATH
EOB

# Generate the munge key
echo "Generating munge key"
umask 0077
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
umask 0022

# Create the slurm user
useradd -c "Slurm scheduler" slurm

cat > /home/slurm/slurm-resume <<EOB
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

mkdir /opt/slurm/etc
cat > /opt/slurm/etc/slurm.conf <<EOB
# slurm.conf file generated by configurator easy.html.
# Put this file on all nodes of your cluster.
# See the slurm.conf man page for more information.
#
ControlMachine=$MASTER_NAME
#ControlAddr=
#
#MailProg=/bin/mail
MpiDefault=none
#MpiParams=ports=#-#
ProctrackType=proctrack/cgroup
ReturnToService=1
SlurmctldPidFile=/var/run/slurmctld.pid
#SlurmctldPort=6817
SlurmdPidFile=/var/run/slurmd.pid
#SlurmdPort=6818
SlurmdSpoolDir=/var/spool/slurmd
SlurmUser=slurm
#SlurmdUser=root
StateSaveLocation=/var/spool/slurmd
SwitchType=switch/none
TaskPlugin=task/cgroup
#
#
# TIMERS
#KillWait=30
#MinJobAge=300
#SlurmctldTimeout=120
#SlurmdTimeout=300
#
#
# SCHEDULING
SchedulerType=sched/backfill
#SchedulerPort=7321
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
#
#
# LOGGING AND ACCOUNTING
AccountingStorageType=accounting_storage/none
ClusterName=cluster
#JobAcctGatherFrequency=30
JobAcctGatherType=jobacct_gather/none
#SlurmctldDebug=3
#SlurmctldLogFile=
#SlurmdDebug=3
#SlurmdLogFile=

# Shut down a node that has been idle for this many seconds
SuspendTime=300
# Decide that something must have gone wrong if a node hasn't woken up in this long
ResumeTimeout=600
# Program used to suspend a node
SuspendProgram=/home/slurm/slurm-suspend
# Program used to resume a node
ResumeProgram=/home/slurm/slurm-resume
# Support the gpu resource type
GresTypes=gpu

$EXTRASLURM

EOB

cat > /opt/slurm/etc/cgroup.conf <<EOB
CgroupMountpoint="/sys/fs/cgroup"
CgroupAutomount=yes
CgroupReleaseAgentDir="/etc/slurm/cgroup"
AllowedDevicesFile="/etc/slurm/cgroup_allowed.conf"
ConstrainCores=yes
ConstrainRAMSpace=yes
TaskAffinity=yes
AllowedSwapSpace=50
ConstrainSwapSpace=yes
ConstrainDevices=yes
EOB

cat > /opt/slurm/etc/cgroup_allowed.conf <<EOB
/dev/null
/dev/urandom
/dev/zero
/dev/sda*
/dev/cpu/*/*
/dev/pts/*
/dev/nvidia*
/dev/infiniband/*
EOB

# Loop through all worker nodes, update hosts file and slurm config
for ((i=0;i<$PARTITION_COUNT;i++)); do
  NVIDIA_ARGS=""
  NODE_COUNT=$(echo $JSON | jq -r ".[$i].scaleNumber")
  NODE_PARAMS=$(echo $JSON | jq -r ".[$i].nodeParameters")
  PARTITION_PARAMS=$(echo $JSON | jq -r ".[$i].partitionParameters")
  WORKER_NAME=$(echo $JSON | jq -r ".[$i].name")
  NVIDIA_CARD=$(echo $JSON | jq -r ".[$i].nvidiaCard")
  NVIDIA_COUNT=$(echo $JSON | jq -r ".[$i].nvidiaCount")
  lastvm=`expr $NODE_COUNT - 1`

  if [ "$NVIDIA_CARD" != "null" ];then
    NVIDIA_ARGS="Gres=gpu:$NVIDIA_CARD:$NVIDIA_COUNT"
    for ((card=0;card<$NVIDIA_COUNT;card++)); do
      echo "NodeName=${WORKER_NAME}[0-${lastvm}] Name=gpu Type=$NVIDIA_CARD File=/dev/nvidia${card}" >> /opt/slurm/etc/gres.conf
    done
  fi

  echo NodeName="$WORKER_NAME[0-"$lastvm"] $NVIDIA_ARGS $NODE_PARAMS State=CLOUD" >> /opt/slurm/etc/slurm.conf
  echo PartitionName=$WORKER_NAME Nodes=$WORKER_NAME[0-"$lastvm"] $PARTITION_PARAMS State=UP >> /opt/slurm/etc/slurm.conf
  IP_BASE="${WORKER_IP_BASE}$i."

  for ((j=0;j<$NODE_COUNT;j++)); do
    worker=$WORKER_NAME$j
    workerip=`expr $j + $WORKER_IP_START`
    echo 'I update host - '$WORKER_NAME$j
    sed "s/master/$worker,$worker.internal.cloudapp.net,$IP_BASE$workerip/" /tmp/ssh-template >> $ssh_known_hosts
    echo $worker >> $shosts_equiv
    echo $WORKER_NAME$i >> /etc/ansible/hosts
    echo $IP_BASE$workerip $worker.internal.cloudapp.net $worker >> /etc/hosts
  done
done


chown slurm /opt/slurm/etc/slurm.conf
mkdir /var/spool/slurmd
chown slurm:slurm /var/spool/slurmd
systemctl daemon-reload
systemctl enable munge
systemctl start munge # Start munged
systemctl enable slurmctld
systemctl start  slurmctld # Start the master daemon service

# Download the SSH configuration files
SSHDCONFIG=/tmp/sshd_config.$$
wget $TEMPLATE_BASE/sshd_config -O $SSHDCONFIG
SSHCONFIG=/tmp/ssh_config.$$
wget $TEMPLATE_BASE/ssh_config -O $SSHCONFIG

# Update slurm.conf with the number of CPUs detected on the compute nodes
# sudo -iu $ADMIN_USERNAME /usr/bin/ansible-playbook create_slurm_conf.yml
# scontrol reconfigure

cp $ssh_known_hosts /etc/ssh/ssh_known_hosts
cp $shosts_equiv /etc/ssh/shosts.equiv
cp $SSHDCONFIG /etc/ssh/sshd_config
cp $SSHCONFIG /etc/ssh/ssh_config
systemctl restart sshd

# This should be removed and fixed
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Make sudo passwordless for AAD Admins
echo '%aad_admins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aad_admins

cp /etc/hosts /data/system/
cp -a /root/.ssh/id_ed25519.pub /data/system/authorized_keys
cp /etc/munge/munge.key /data/system
mkdir /data/system/ssh
cp -a /etc/ssh/s* /data/system/ssh/

cat > /etc/cron.d/sync-aadpasswd <<EOB
* * * * * root rsync -a /etc/aadpasswd /data/system/aadpasswd
EOB

# Install some local packages
yum -y install glfw-devel opencl-headers openmpi3-devel

exit 0

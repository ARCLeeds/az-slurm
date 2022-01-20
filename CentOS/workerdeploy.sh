#!/bin/bash
set -x
exec >& /root/install.log

# This should be removed and fixed
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Sort EPEL out early
yum -y install epel-release

# Just discover if we have an nvidia card, and update and install a driver if so
#if lspci|grep -i nvidia;then
# Install CUDA everywhere, as it also get us working OpenCL
if true;then
  yum -y install dkms kernel-devel
  CUDA_REPO_PKG=cuda-repo-rhel7-10.2.89-1.x86_64.rpm
  yum -y install --nogpg http://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/${CUDA_REPO_PKG}
  yum -y upgrade --exclude=WALinuxAgent
  PACKAGE=cuda
  if lspci|grep -i "Tesla T4";then
    PACKAGE="nvidia-driver-branch-470.x86_64 cuda"
  fi
  yum -y install $PACKAGE
  cat > /etc/profile.d/nvidia.sh <<'EOB'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export LIBRARY_PATH=/usr/local/cuda/lib64:$LIBRARY_PATH
export CPATH=/usr/local/cuda/include:$CPATH
EOB

fi

SLURMVERSION=20.02.6

yum -y install nfs-utils
systemctl enable rpcbind
systemctl start rpcbind

setsebool -P use_nfs_home_dirs=on

mkdir /data
cat >> /etc/fstab <<EOB
master:/data	/data	nfs	defaults	0	0
master:/data/home	/home	nfs	defaults	0 0
master:/opt	/opt	nfs	defaults	0	0
EOB
mount -a

rsync -a /data/system/ssh/* /etc/ssh/
service sshd restart

mkdir -p /root/.ssh
cat /data/system/authorized_keys > /root/.ssh/authorized_keys

chmod g-w /var/log
useradd -c "Slurm scheduler" slurm
yum -y install munge

cat > /etc/systemd/system/slurmd.service <<'EOB'
[Unit]
Description=Slurm node daemon
After=munge.service network.target remote-fs.target opt.mount
ConditionPathExists=/opt/slurm/etc/slurm.conf

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmd
ExecStart=/opt/slurm/sbin/slurmd $SLURMD_OPTIONS
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/var/run/slurmd.pid
KillMode=process
LimitNOFILE=51200
LimitMEMLOCK=infinity
LimitSTACK=infinity
Delegate=yes

[Install]
WantedBy=multi-user.target
EOB

cat > /etc/profile.d/slurm.sh <<'EOB'
export PATH=/opt/slurm/bin:$PATH
export MANPATH=/opt/slurm/man:$MANPATH
EOB

cat > /etc/profile.d/zz-local.sh <<'EOB'
. /opt/zz-local.sh >& /dev/null
EOB

install -m 400 -o munge -g munge /data/system/munge.key /etc/munge/munge.key
md5sum /data/system/munge.key /etc/munge/munge.key
systemctl daemon-reload
systemctl enable munge
systemctl start munge
systemctl enable slurmd

# Install OpenMPI
yum -y install openmpi3-devel
# Fix broken tmpfilesd
systemctl enable systemd-tmpfiles-setup

# Make sudo passwordless for AAD Admins
echo '%aad_admins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aad_admins
cat /data/system/hosts > /etc/hosts
ln -sf /data/system/aadpasswd /etc/aadpasswd

# Some random local installs
yum -y install glfw-devel opencl-headers

# If we've got nvidia, schedule a reboot, else start slurmd
if lspci|grep -i nvidia;then
  shutdown -r +1
else
  systemctl start slurmd
fi

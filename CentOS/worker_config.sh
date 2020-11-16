echo __ADMINPASS__ | sudo -S date
sudo sh -c "cat /tmp/hosts >> /etc/hosts"
sudo chmod g-w /var/log
sudo useradd -c "Slurm scheduler" slurm
sudo yum -y install epel-release
sudo yum -y install munge
sudo yum -y install /tmp/slurm-17.11.8-1.el7.x86_64.rpm  /tmp/slurm-example-configs-17.11.8-1.el7.x86_64.rpm /tmp/slurm-libpmi-17.11.8-1.el7.x86_64.rpm /tmp/slurm-pam_slurm-17.11.8-1.el7.x86_64.rpm /tmp/slurm-slurmd-17.11.8-1.el7.x86_64.rpm
sudo cp -f /tmp/munge.key /etc/munge/munge.key
sudo chown munge /etc/munge/munge.key
sudo chgrp munge /etc/munge/munge.key
sudo rm -f /tmp/munge.key
sudo systemctl daemon-reload
sudo systemctl enable munge
sudo systemctl start munge
sudo cp -f /tmp/slurm.conf /etc/slurm/slurm.conf
sudo chown slurm /etc/slurm/slurm.conf
sudo systemctl enable slurmd
sudo systemctl start  slurmd
sudo yum -y install openmpi
sudo sed -i -- 's/azureuser ALL=(ALL) ALL/azureuser ALL=(ALL) NOPASSWD:ALL/g' /etc/sudoers.d/waagent
sudo yum -y install nfs-utils
sudo systemctl enable rpcbind
sudo systemctl start rpcbind
sudo mkdir /data
sudo bash -c 'echo -e "master:/data\t/data\tnfs\tintr\t0 0" >> /etc/fstab'
sudo mount /data
sudo bash -c 'echo -e "/data/home /home none bind 0 0" >> /etc/fstab'
sudo mount -a
sudo yum -y install openmpi3-devel
sudo setsebool -P use_nfs_home_dirs=on

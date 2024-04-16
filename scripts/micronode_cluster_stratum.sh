#!/bin/bash

# Make sure we are not running as root, but that we have sudo privileges.
if [ "$(id -u)" = "0" ]; then
   echo "This script must NOT be run as root (or with sudo)!"
   echo "if you need to create a sudo user (e.g. satoshi), run the following commands:"
   echo "   sudo adduser satoshi"
   echo "   sudo usermod -aG sudo satoshi"
   echo "   sudo su satoshi # Switch to the new user"
   exit 1
elif [ "$(sudo -l | grep '(ALL : ALL) ALL' | wc -l)" = 0 ]; then
   echo "You do not have enough sudo privileges!"
   exit 1
fi
cd ~; sudo pwd # Print Working Directory; have the user enable sudo access if not already.

# Give the user pertinent information about this script and how to use it.
cat << EOF | sudo tee ~/readme.txt
This readme was generated by the "micronode_cluster_stratum.sh" install script.
The "micronode_cluster_stratum.sh" script installs a "stratum" micronode (within a cluster).
The Stratum node is used to manage the microcurrency mining operation for a "minibank".
To run this script, you'll need the Bitcoin Core micronode download URL (tar.gz file) with its SHA 256 Checksum to continue.
Also, you will need to plug in the USB drive that contains the encrypted mining wallet that was generated from the wallet install.
To execute this script, login as a sudo user (that is not root) and execute the following commands:
    sudo apt-get -y install git
    cd ~; git clone https://github.com/satoshiware/microbank
    bash ./microbank/scripts/micronode_cluster_stratum.sh
    rm -rf microbank

FYI:
    Use the mnconnect utility (just type "mnconnect" at the prompt) to create, view, or delete the connection with the p2p node.
    Use the stmutility tool to view all the pertinent informaiton for a healthy mining operation (and setup a remote mining operations)

    The "$USER/.ssh/authorized_keys" file contains administrator login keys.
    The "/var/lib/bitcoin/micro" directory contains debug logs, blockchain, etc.
    The bitcoind's log files can be view with this file: "/var/log/bitcoin/micro/debug.log" (links to /var/lib/bitcoin/micro/debug.log)
    The "/var/lib/bitcoin/micro/wallets/mining" directory contains the (encrypted) mining wallet.

    The "sudo systemctl status bitcoind" command show the status of the bitcoin daemon.

Hardware:
    Rasperry Pi Compute Module 4: CM4004000 (w/ Compute Blade)
    4GB RAM
    M.2 PCI SSD 500MB
    Netgear 5 Port Switch (PoE+ @ 120W)
EOF
read -p "Press the enter key to continue..."

# Create .ssh folder and authorized_keys file if it does not exist
if ! [ -f ~/.ssh/authorized_keys ]; then
    sudo mkdir -p ~/.ssh
    sudo touch ~/.ssh/authorized_keys
    sudo chown -R $USER:$USER ~/.ssh
    sudo chmod 700 ~/.ssh
    sudo chmod 600 ~/.ssh/authorized_keys
fi

# Run latest updates and upgrades
sudo apt-get -y update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install --only-upgrade openssh-server # Upgrade seperatly to ensure non-interactive mode
sudo apt-get -y upgrade

# Install Packages
sudo apt-get -y install wget psmisc autossh ssh ufw python3 jq
sudo apt-get -y install build-essential yasm autoconf automake libtool libzmq3-dev
sudo apt-get -y install pkg-config # ckpool/ckproxy will not successfully configure/compile without this package using Debian Bookworm (x12)

# Install rpcauth Utility
sudo mkdir -p /usr/share/python
sudo mv ~/microbank/python/rpcauth.py /usr/share/python/rpcauth.py
sudo chmod +x /usr/share/python/rpcauth.py
echo "#"\!"/bin/sh" | sudo tee /usr/share/python/rpcauth.sh
echo "python3 /usr/share/python/rpcauth.py \$1 \$2" | sudo tee -a /usr/share/python/rpcauth.sh
sudo ln -s /usr/share/python/rpcauth.sh /usr/bin/rpcauth
sudo chmod 755 /usr/bin/rpcauth

# Download Bitcoin Core (micro), Verify Checksum
read -p "Bitcoin Core URL (.tar.gz) source (/w compiled microcurrency): " SOURCE
read -p "SHA 256 Checksum for the .tar.gz source file: " CHECKSUM

wget $SOURCE
if ! [ -f ~/${SOURCE##*/} ]; then echo "Error: Could not download source!"; exit 1; fi
if [[ ! "$(sha256sum ~/${SOURCE##*/})" == *"$CHECKSUM"* ]]; then
    echo "Error: SHA 256 Checksum for file \"~/${SOURCE##*/}\" was not what was expected!"
    exit 1
fi
tar -xzf ${SOURCE##*/}
rm ${SOURCE##*/}

# Install Binaries
sudo install -m 0755 -o root -g root -t /usr/bin bitcoin-install/bin/*
rm -rf bitcoin-install

# Prepare Service Configuration
cat << EOF | sudo tee /etc/systemd/system/bitcoind.service
[Unit]
Description=Bitcoin daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/bitcoind -micro -daemonwait -pid=/run/bitcoin/bitcoind.pid -conf=/etc/bitcoin.conf -datadir=/var/lib/bitcoin
ExecStop=/usr/bin/bitcoin-cli -micro -conf=/etc/bitcoin.conf -datadir=/var/lib/bitcoin stop

Type=forking
PIDFile=/run/bitcoin/bitcoind.pid
Restart=always
RestartSec=30
TimeoutStartSec=infinity
TimeoutStopSec=600

### Run as bitcoin:bitcoin ###
User=bitcoin
Group=bitcoin

### /run/bitcoin ###
RuntimeDirectory=bitcoin
RuntimeDirectoryMode=0710

### /var/lib/bitcoin ###
StateDirectory=bitcoin
StateDirectoryMode=0710

### Hardening measures ###
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

#Create a bitcoin System User
sudo useradd --system --shell=/sbin/nologin bitcoin

# Wrap the Bitcoin CLI Binary with its Runtime Configuration
echo "alias btc=\"sudo -u bitcoin /usr/bin/bitcoin-cli -micro -datadir=/var/lib/bitcoin -conf=/etc/bitcoin.conf\"" | sudo tee -a /etc/bash.bashrc # Reestablish alias @ boot

# Generate Strong Bitcoin RPC Password
BTCRPCPASSWD=$(openssl rand -base64 16)
BTCRPCPASSWD=${BTCRPCPASSWD//\//0} # Replace '/' characters with '0'
BTCRPCPASSWD=${BTCRPCPASSWD//+/1} # Replace '+' characters with '1'
BTCRPCPASSWD=${BTCRPCPASSWD//=/} # Replace '=' characters with ''
echo $BTCRPCPASSWD | sudo tee /root/rpcpasswd
BTCRPCPASSWD="" # Erase from memory
sudo chmod 400 /root/rpcpasswd

# Generate Bitcoin Configuration File with the Appropriate Permissions
cat << EOF | sudo tee /etc/bitcoin.conf
server=1
$(rpcauth satoshi $(sudo cat /root/rpcpasswd) | grep 'rpcauth')
[micro]
EOF
sudo chown root:bitcoin /etc/bitcoin.conf
sudo chmod 640 /etc/bitcoin.conf

# Configure bitcoind's Log Files; Prevents them from Filling up the Partition
cat << EOF | sudo tee /etc/logrotate.d/bitcoin
/var/lib/bitcoin/micro/debug.log {
$(printf '\t')create 660 root bitcoin
$(printf '\t')daily
$(printf '\t')rotate 14
$(printf '\t')compress
$(printf '\t')delaycompress
$(printf '\t')sharedscripts
$(printf '\t')postrotate
$(printf '\t')$(printf '\t')killall -HUP bitcoind
$(printf '\t')endscript
}
EOF

# Setup a Symbolic Link to Standardize the Location of bitcoind's Log Files
sudo mkdir -p /var/log/bitcoin/micro
sudo ln -s /var/lib/bitcoin/micro/debug.log /var/log/bitcoin/micro/debug.log
sudo chown root:bitcoin -R /var/log/bitcoin
sudo chmod 660 -R /var/log/bitcoin

# Install/Setup/Enable the Uncomplicated Firewall (UFW)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh # Open Default SSH Port
sudo ufw --force enable # Enable Firewall @ Boot and Start it now!

# Open firewall to the stratum port for any local ip
PNETWORK=$(echo $(hostname -I) | cut -d '.' -f 1)
read -p "Open firewall to the stratum port (if not already) for any local ip? (y|n): "
if [[ "${REPLY}" = "y" || "${REPLY}" = "Y" ]]; then
    if [[ ${PNETWORK} = "192" ]]; then
        sudo ufw allow from 192.168.0.0/16 to any port 3333
    elif [[ ${PNETWORK} = "172" ]]; then
        sudo ufw allow from 192.168.0.0/16 to any port 3333
    elif [[ ${PNETWORK} = "10" ]]; then
        sudo ufw allow from 192.168.0.0/16 to any port 3333
    fi
fi

# Install/Setup/Enable SSH(D)
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config # Disable password login
sudo sed -i 's/X11Forwarding yes/#X11Forwarding no/g' /etc/ssh/sshd_config # Disable X11Forwarding (default value)
sudo sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding Local/g' /etc/ssh/sshd_config # Only allow local port forwarding
sudo sed -i 's/#.*StrictHostKeyChecking ask/\ \ \ \ StrictHostKeyChecking yes/g' /etc/ssh/ssh_config # Enable strict host verification

echo -e "\nMatch User *,"'!'"stratum,"'!'"root,"'!'"$USER" | sudo tee -a /etc/ssh/sshd_config
echo -e "\tAllowTCPForwarding no" | sudo tee -a /etc/ssh/sshd_config
echo -e "\tPermitTTY no" | sudo tee -a /etc/ssh/sshd_config
echo -e "\tForceCommand /usr/sbin/nologin" | sudo tee -a /etc/ssh/sshd_config

echo -e "\nMatch User stratum" | sudo tee -a /etc/ssh/sshd_config
echo -e "\tPermitTTY no" | sudo tee -a /etc/ssh/sshd_config
echo -e "\tPermitOpen localhost:3333" | sudo tee -a /etc/ssh/sshd_config # Denies any request of local forwarding besides localhost:3333 (stratum port)

# Setup a "no login" user called "stratum"
sudo useradd -s /bin/false -m -d /home/stratum stratum

# Create (stratum) .ssh folder; Set ownership and permissions
sudo mkdir -p /home/stratum/.ssh
sudo touch /home/stratum/.ssh/authorized_keys
sudo chown -R stratum:stratum /home/stratum/.ssh
sudo chmod 700 /home/stratum/.ssh
sudo chmod 600 /home/stratum/.ssh/authorized_keys

# Generate public/private keys (non-encrytped)
sudo ssh-keygen -t ed25519 -f /root/.ssh/p2pkey -N "" -C ""

# Create known_hosts file
sudo touch /root/.ssh/known_hosts

# Create systemd Service File
cat << EOF | sudo tee /etc/systemd/system/p2pssh@.service
[Unit]
Description=AutoSSH %I Tunnel Service
Before=bitcoind.service
After=network-online.target

[Service]
Environment="AUTOSSH_GATETIME=0"
EnvironmentFile=/etc/default/p2pssh@%i
ExecStart=/usr/bin/autossh -M 0 -NT -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o "ServerAliveCountMax 3" -i /root/.ssh/p2pkey -L \${LOCAL_PORT}:localhost:\${FORWARD_PORT} -p \${TARGET_PORT} p2p@\${TARGET}

RestartSec=5
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Set stratum port configuration
echo $(python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()') | sudo tee /etc/stratum_port

# Compile/Install CKPool/CKProxy
git clone https://github.com/satoshiware/ckpool
cd ckpool
./autogen.sh
./configure -prefix /usr
make clean
make
sudo make install
cd ..; rm -rf ckpool

# Create a ckpool System User
sudo useradd --system --shell=/sbin/nologin ckpool

# Create ckpool Log Folders
sudo mkdir -p /var/log/ckpool
sudo chown root:ckpool -R /var/log/ckpool
sudo chmod 670 -R /var/log/ckpool

# Create ckpool.service (Systemd)
cat << EOF | sudo tee /etc/systemd/system/ckpool.service
[Unit]
Description=ckpool (Stratum) Server
After=network-online.target
Wants=bitcoind.service

[Service]
ExecStart=/usr/bin/ckpool --log-shares --killold --config /etc/ckpool.conf

Type=simple
PIDFile=/tmp/ckpool/main.pid
Restart=always
RestartSec=30
TimeoutStopSec=30

### Run as ckpool:ckpool ###
User=ckpool
Group=ckpool

### Hardening measures ###
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF

# Reload/Enable System Control for new processes
sudo systemctl daemon-reload
sudo systemctl enable ssh
sudo systemctl enable bitcoind --now
echo "waiting a few seconds for bitcoind to start"; sleep 15

# Copy (via USB) & load the (encrypted) mining wallet (generated on the "Wallet" micronode)
sudo mkdir -p /media/usb
sudo mount /dev/sda1 /media/usb

sudo -u bitcoin mkdir -p /var/lib/bitcoin/micro/wallets/mining
sudo chmod 700 /var/lib/bitcoin/micro/wallets/mining
sudo install -C -m 600 -o bitcoin -g bitcoin /media/usb/mining.dat /var/lib/bitcoin/micro/wallets/mining/wallet.dat

sudo umount /dev/sda1

sudo -u bitcoin /usr/bin/bitcoin-cli -micro -datadir=/var/lib/bitcoin -conf=/etc/bitcoin.conf loadwallet mining true

# Create ckpool Configuration File
MININGADDRESS=$(sudo -u bitcoin /usr/bin/bitcoin-cli -micro -datadir=/var/lib/bitcoin -conf=/etc/bitcoin.conf -rpcwallet=mining getnewaddress "ckpool")
cat << EOF | sudo tee /etc/ckpool.conf
{
"btcd" : [
$(printf '\t'){
$(printf '\t')"url" : "localhost:19332",
$(printf '\t')"auth" : "satoshi",
$(printf '\t')"pass" : "$(sudo cat /root/rpcpasswd)",
$(printf '\t')"notify" : true
$(printf '\t')}
],
"btcaddress" : "${MININGADDRESS}",
"btcsig" : "",
"serverurl" : [
$(printf '\t')"0.0.0.0:3333"
],
"mindiff" : 1,
"startdiff" : 42,
"maxdiff" : 0,
"zmqblock" : "tcp://127.0.0.1:28332",
"logdir" : "/var/log/ckpool"
}
EOF

sudo chown root:ckpool /etc/ckpool.conf
sudo chmod 440 /etc/ckpool.conf

# Reload/Enable System Control for ckpool
sudo systemctl daemon-reload
sudo systemctl enable ckpool

# Configure ckpool's Log Files; Prevents them from Filling up the Partition
cat << EOF | sudo tee /etc/logrotate.d/ckpool
/var/log/ckpool/ckpool.log {
$(printf '\t')create 644 ckpool ckpool
$(printf '\t')daily
$(printf '\t')rotate 14
$(printf '\t')compress
$(printf '\t')delaycompress
$(printf '\t')sharedscripts
}
EOF

# Create cron job to call the "stmutility" --update routine every 15 minutes
(sudo crontab -l; echo "*/15 * * * * stmutility --update") | sudo crontab -

# Install the micronode connection and stratum utilities
bash ~/microbank/scripts/mnconnect.sh -i
bash ~/microbank/scripts/stmutility.sh -i

# Restart the machine
sudo reboot now
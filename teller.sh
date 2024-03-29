#!/bin/bash

# Make sure we are not running as root, but that we have sudo privileges.
if [ "$(id -u)" = "0" ]; then
   echo "This script must NOT be run as root (or with sudo)!"
   exit 1
elif [ "$(sudo -l | grep '(ALL : ALL) ALL' | wc -l)" = 0 ]; then
   echo "You do not have enough sudo privileges!"
   exit 1
fi

# Universal envrionment variables
BTC=$(cat /etc/bash.bashrc | grep "alias btc=" | cut -d "\"" -f 2)
UNLOCK="$BTC -rpcwallet=bank walletpassphrase $(sudo cat /root/passphrase) 600"
MINING_UNLOCK="$BTC -rpcwallet=mining walletpassphrase $(sudo cat /root/passphrase) 600"

# See which teller parameter was passed and execute accordingly
if [[ $1 = "--help" ]]; then # Show all possible paramters
    cat << EOF
    Options:
      --help        Display this help message and exit
      --install     Install this script (teller) in /usr/local/sbin/teller

      --watch       See all addresses being "watched" with corresponding details
                    Parameters: (ADDRESS)
                        Note: Include an address (optional) to see just the details for that address
      --record      Record or laod a public address into the watch wallet (can also be used to update the NAME and DESCRIPTION)
                    Parameters: ADDRESS  NAME  DESCRIPTION  (NOSCAN)
                        Note: Prevent the blockchain from being rescanned by including "NOSCAN" (optional)
                        Note: To rescan the blockchain manually enter "btc -rpcwallet=watch rescanblockchain"
                              To rescan the Import wallet on the blockchain manually enter "btc -rpcwallet=import rescanblockchain"
      --remove      Remove watch wallet
                    Parameters: ADDRESS

      --sweep       Sweep or import private keys into the Import wallet. It's good practice to transfer all monies from the Import wallet each session.
                    This is an overloaded routine:
                        Show Balance                Paramters:  None
                        Import Private Key          Paramters:  PRIVATE_KEY  (NOSCAN)          Same notes under --record routine
                        Transfer to Bank Wallet     Paramters:  AMOUNT  (PRIORITY)             Same notes under --transfer routine
                        Send                        Paramters:  ADDRESS  AMOUNT  (PRIORITY)    Same notes under --send routine
      --balances    Show balances for the Mining and Bank wallets
      --utxos       Show the number of UTXOs in the Mining and Bank wallets
                        Note: If the UTXO quantity is really high, this routine may take awhile
      --transfer    Transfer funds from the Mining wallet to the Bank wallet
                    Parameters: AMOUNT  (PRIORITY)
                        Note: PRIORITY is optional (default = NORMAL). It helps determine the fee rate. It can be set to NOW, NORMAL, ECONOMICAL, or CHEAPSKATE.
                              The PRIORITY is negligible until blocks are consistently full
                        Note: Enter '.' for the amount to empty the Bank wallet completly
                              Full transfers are incompatible with the --bump routine; also, ECONOMICAL and CHEAPSKATE priorities are upgraded to "NORMAL".

      --send        Send funds (coins) from the Bank wallet
                    Parameters: ADDRESS  AMOUNT  (PRIORITY)
                        Note: Same notes under --transfer routine
      --bump        Bumps the fee of all (recent) outgoing transactions that are BIP 125 replaceable and not confirmed
      --receive     Create new address to receive funds into the Bank wallet
      --mining      Create new address to receive funds into the Mining wallet
      --recent      Show recent (last 50) Bank wallet transactions

      --blockchain  Show blockchain stats
      --mempool     Show mempool stats
      --network     Show network stats
EOF
elif [[ $1 = "--install" ]]; then # Installing this script (teller) in /usr/local/sbin/teller
    # Installing the payouts script
    echo "Installing this script (teller) in /usr/local/sbin/"
    if [ -f /usr/local/sbin/teller ]; then
        echo "This script (teller) already exists in /usr/local/sbin!"
        read -p "Would you like to reinstall it? (y|n): "
        if [[ "${REPLY}" = "y" || "${REPLY}" = "Y" ]]; then
            sudo rm /usr/local/sbin/teller
        else
            exit 0
        fi
    fi
    sudo cat $0 | sed '/Install this script (teller)/d' | sudo tee /usr/local/sbin/teller > /dev/null
    sudo sed -i 's/$1 = "--install"/"a" = "b"/' /usr/local/sbin/teller # Make it so this code won't run again in the newly installed script
    sudo chmod +x /usr/local/sbin/teller

    # Create the file with the needed envrionment variables if it has not been done already
    if [ ! -f /etc/default/teller.env ]; then
        read -p "Number of blocks in each halving (e.g. 262800): "; echo "HALVINGINTERVAL=$REPLY" | sudo tee -a /etc/default/teller.env > /dev/null
        read -p "Number of seconds (typically) between blocks (e.g. 120): "; echo "BLOCKINTERVAL=$REPLY" | sudo tee -a /etc/default/teller.env > /dev/null
    else
        echo "The environment file \"/etc/default/teller.env\" already exits."
    fi

elif [[ $1 = "--watch" ]]; then # See all addresses being "watched" with corresponding details. Include an address (optional) to see just the details for that address
    ADDRESS="${2,,}"
    if [[ ! -z $ADDRESS ]]; then
        if ! [[ $($BTC validateaddress $ADDRESS | jq '.isvalid') == "true" ]]; then
            echo "Error! Address provided is not correct or Bitcoin Core (microcurrency mode) is down!"; exit 1
        fi
    fi

    # Get data from the blockchain
    readarray -t RECEIVED < <($BTC -rpcwallet=watch listreceivedbyaddress 0 true true $ADDRESS | jq -r '.[] | .address, .amount, .label, (.txids | length)')
    data=""
    for ((i = 0 ; i < ${#RECEIVED[@]} ; i = i + 4)); do # Go through each address to find the remaining balance and number of UTXOs while prepping the data table
        if [[ ${RECEIVED[i + 2]} != *"REMOVED"* ]]; then
            tmp=$($BTC -rpcwallet=watch listunspent 0 9999999 "[\"${RECEIVED[i]}\"]" | jq '.[].amount' | awk '{sum += $0; count++} END{printf("%.8f;%d", sum, count)}') # Get Balance and UTXOs
            data="$data""${RECEIVED[i]};${RECEIVED[i+1]};${tmp};${RECEIVED[i+3]};${RECEIVED[i+2]}"$'\n' # Address, Received, [Balance, UTXOs], TXIDs, [name, description]
            echo -n "." # Show user progress is being made
        fi
    done

    # Print data table formatted properly
    echo $'\n'
    echo "                 Address                      Received          Spent          Balance      UTXOs  TXIDs   Used?   Name                           Description"
    echo "------------------------------------------  --------------  --------------  --------------  -----  -----  -------  ----------------------------   ----------------------------"
    awk -F ';' '{printf("%s %15.8f %15.8f %15.8f %6d %6d %5d     %-30s %-s\n", $1, $2, $2 - $3, $3, $4, $5, $5 - $4, $6, $7)}' <<< ${data%?}
    echo ""

elif [[ $1 = "--record" ]]; then # Record or laod a public address into the watch wallet (can also be used to update the NAME and DESCRIPTION)
    ADDRESS="${2,,}"; NAME=$3; DESCRIPTION=$4
    if [[ -z $ADDRESS || -z $NAME || -z $DESCRIPTION ]]; then echo "Error! Insufficient Parameters!"; exit 1; fi
    if ! [[ $($BTC validateaddress $ADDRESS | jq '.isvalid') == "true" ]]; then
        echo "Error! Address provided is not correct or Bitcoin Core (microcurrency mode) is down!"; exit 1
    fi

    if [[ -z $5 ]]; then # If the 5th pameter is absent then rescan the blockchain
        echo ""; echo -n "    Scanning the entire blockchain... This could take awhile! "
        while true;do echo -n .;sleep 1;done & # Show user that progress is being made
        $BTC -rpcwallet=watch importaddress "$ADDRESS" "${NAME//;};${DESCRIPTION//;}" true
        kill $!; trap 'kill $!' SIGTERM
        echo "done"; echo ""

    else
        $BTC -rpcwallet=watch importaddress "$ADDRESS" "${NAME//;};${DESCRIPTION//;}" false
    fi

elif [[ $1 = "--remove" ]]; then # Remove watch wallet
    $0 --record $2 "REMOVED" "REMOVED" NOSCAN

elif [[ $1 = "--sweep" ]]; then # Sweep or import private keys into the Import wallet. This is an overloaded routine!
    if [[ -z $2 ]]; then # Show Balance - Paramters: None
        echo ""; echo "    Balance: $($BTC -rpcwallet=import getbalance)"; echo ""

    elif [[ $2 =~ ^[0-9]+\.?[0-9]*$ || $2 == "." ]]; then # Transfer to Bank Wallet: AMOUNT (PRIORITY)
        if [[ -z $3 ]]; then PRIORITY="normal"; else PRIORITY=${3,,}; fi
        $0 --send $($BTC -rpcwallet=bank getnewaddress) $2 $PRIORITY "SWEEP"

    elif [[ -z $3 || ${3,,} == "noscan" ]]; then # Import Private Key: PRIVATE_KEY (NOSCAN)
        if [[ -z $3 ]]; then
            echo ""; echo -n "    Scanning the entire blockchain... This could take awhile! "
            while true;do echo -n .;sleep 1;done & # Show user that progress is being made
            $BTC -rpcwallet=import importprivkey $2 "" true
            kill $!; trap 'kill $!' SIGTERM
            echo "done"; echo ""
        else
            $BTC -rpcwallet=import importprivkey $2 "" false
        fi

    else # Send ADDRESS AMOUNT (PRIORITY)
        if [[ -z $4 ]]; then PRIORITY="normal"; else PRIORITY=${4,,}; fi
        $0 --send $2 $3 $PRIORITY "SWEEP"
    fi

elif [[ $1 = "--balances" ]]; then # Show balances for the Mining and Bank wallets
    echo ""
    cat << EOF
    Mining Wallet:
        Unconfirmed Balance:    $($BTC -rpcwallet=mining getbalances | jq '.mine.untrusted_pending' | awk '{printf("%.8f", $1)}')
        Trusted Balance:        $($BTC -rpcwallet=mining getbalance)

    Bank Wallet:
        Unconfirmed Balance:    $($BTC -rpcwallet=bank getbalances | jq '.mine.untrusted_pending' | awk '{printf("%.8f", $1)}')
        Trusted Balance:        $($BTC -rpcwallet=bank getbalance)
EOF
    echo ""

elif [[ $1 = "--utxos" ]]; then # Show the number of UTXOs in the Mining and Bank wallets
    echo ""
    cat << EOF
    Mining Wallet UTXO Quantity:    $($BTC -rpcwallet=mining listunspent 0 9999999 | jq '.[].amount' | awk '{count++} END{printf("%d", count)}')
    Bank Wallet UTXO Quantity:      $($BTC -rpcwallet=bank listunspent 0 9999999 | jq '.[].amount' | awk '{count++} END{printf("%d", count)}')
EOF
    echo ""

elif [[ $1 = "--transfer" ]]; then # Transfer funds from the Mining wallet to the Bank wallet
    AMOUNT=$2; PRIORITY=${3,,}
    if [[ -z $PRIORITY ]]; then PRIORITY="normal"; fi
    $0 --send $($BTC -rpcwallet=bank getnewaddress) $AMOUNT $PRIORITY "INTERNAL"

elif [[ $1 = "--send" ]]; then # Send funds (coins) from the Bank wallet
    ADDRESS="${2,,}"; AMOUNT=$3; PRIORITY=${4,,}; TRANSFER=$5

    # Is it an internal transfer
    if [[ $TRANSFER == "INTERNAL" ]]; then
        wallet="mining"
    elif [[ $TRANSFER == "SWEEP" ]]; then
        wallet="import"
    else
        wallet="bank"
    fi

    # Input Checking
    if [[ -z $ADDRESS || -z $AMOUNT ]]; then
        echo "Error! Insufficient Parameters!"; exit 1
    elif ! [[ $($BTC validateaddress $ADDRESS | jq '.isvalid') == "true" ]]; then
        echo "Error! Address provided is not correct or Bitcoin Core (microcurrency mode) is down!"; exit 1
    elif [[ $AMOUNT == "." ]]; then # Should we send it all?
        AMOUNT=$($BTC -rpcwallet=$wallet getbalance) # Get the full amount
        if [[ ! $PRIORITY == "now" ]]; then PRIORITY="normal"; fi # Override priority if set too low
        SEND_ALL=", \"subtract_fee_from_outputs\": [0]" # Extra option for send command in order to empty the Bank wallet completly
    elif ! [[ $AMOUNT =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Error! Amount is not a number!"; exit 1
    elif [[ $(awk '{printf("%15.f\n", $1 * 100000000)}' <<< ${data%?} <<< $AMOUNT) -lt "10000" ]]; then
        echo "Error! Amount is not large enough!"; exit 1
    else
        SEND_ALL=""
    fi

    # Determine paramters that govern fee rate
    if [[ $PRIORITY == "now" ]]; then
        TARGET=1; ESTIMATION="conservative"
    elif [[ -z $PRIORITY || $PRIORITY == "normal" ]]; then
        TARGET=12; ESTIMATION="economical"
    elif [[ $PRIORITY == "economical" ]]; then
        TARGET=144; ESTIMATION="economical"
    elif [[ $PRIORITY == "cheapskate" ]]; then
        TARGET=1008; ESTIMATION="economical"
    else
        echo "Error! Priority could not be determined!"; exit 1
    fi

    $UNLOCK; $MINING_UNLOCK; $BTC -rpcwallet=$wallet send "{\"$ADDRESS\": $AMOUNT}" $TARGET $ESTIMATION null "{\"replaceable\": true${SEND_ALL}}"

elif [[ $1 = "--bump" ]]; then # Bumps the fee of all (recent) outgoing transactions that are BIP 125 replaceable and not confirmed
    WALLETS=("bank" "mining" "import"); bump_flag=""
    for wallet in "${WALLETS[@]}"; do
        readarray -t TXS < <($BTC -rpcwallet=$wallet listtransactions "*" 40 0 false | jq -r '.[] | .confirmations, .txid, .category')
        for ((i = 0 ; i < ${#TXS[@]} ; i = i + 3)); do
            if [[ ${TXS[i]} -eq 0 && ${TXS[i + 2]} == "send" ]]; then
                $UNLOCK; $MINING_UNLOCK; $BTC -rpcwallet=$wallet bumpfee ${TXS[i + 1]}
                bump_flag="true"
            fi
        done
    done

    if [[ -z $bump_flag ]]; then echo "Looks like there is nothing to bump!"; fi

elif [[ $1 = "--receive" ]]; then # Create new address to receive funds into the Bank wallet
    echo ""; $BTC -rpcwallet=bank getnewaddress; echo ""

elif [[ $1 = "--mining" ]]; then # Create new address to receive funds into the Mining wallet
    echo ""; $BTC -rpcwallet=mining getnewaddress; echo ""

elif [[ $1 = "--recent" ]]; then # Show recent (last 40) Bank wallet transactions
    readarray -t TXS < <($BTC -rpcwallet=bank listtransactions "*" 40 0 false | jq -r '.[] | .category, .amount, .confirmations, .time, .address, .txid')

    # Get data from the blockchain
    data=""
    for ((i = 0 ; i < ${#TXS[@]} ; i = i + 6)); do # Go through each address to find the remaining balance and number of UTXOs while prepping the data table
        # How confirmed is the transaction? "Yes" (6 blocks or greater), "Almost" (between 1 and 5 blocks), and "no" (not on the blockchain).
        if [[ ${TXS[i+2]} -ge 6 ]]; then
            TXS[i+2]="Yes"
        elif [[ ${TXS[i+2]} -ge 1 ]]; then
            TXS[i+2]="Almost"
        elif [[ ${TXS[i+2]} -lt 0 ]]; then
            TXS[i+2]="Bumped"
        else
            TXS[i+2]="No"
        fi

        data="$data""${TXS[i]};${TXS[i+1]//-};${TXS[i+2]};$(date -d @${TXS[i+3]} '+%y/%m/%d %H:%M');${TXS[i+4]};${TXS[i+5]}"$'\n' # Direction, Amount, Confirmations, Time, Address, TXID
    done

    # Print data table formatted properly
    echo $'\n'
    echo "Direction       Amount      Confirmed   YY/MM/DD Time   Address                                     TXID"
    echo "---------  ---------------  ---------  ---------------  ------------------------------------------  ----------------------------------------------------------------"
    awk -F ';' '{printf("%7s    %-15.8f  %-8s  %15s   %s  %s\n", $1, $2, $3, $4, $5, $6)}' <<< ${data%?}

elif [[ $1 = "--blockchain" ]]; then # Show blockchain stats
    # Load envrionment variables and then verify
    if [[ -f /etc/default/teller.env ]]; then
        source /etc/default/teller.env
        if [[ -z $HALVINGINTERVAL || -z $BLOCKINTERVAL ]]; then
            echo ""; echo "Error! Not all variables have proper assignments in the \"/etc/default/teller.env\" file"; exit 1;
        fi
    else
        echo "Error! The \"/etc/default/teller.env\" environment file does not exist!"
        echo "Run this script with the \"-i\" or \"--install\" parameter."
        exit 1;
    fi

    # Generate and print blockchain stats
    BLOCK_HEIGHT=$($BTC getblockcount)
    BLOCKCHAIN_INFO=$($BTC getblockchaininfo)
    echo ""
    cat << EOF
    Blockchain Size:        $(awk -v size=$(jq '.size_on_disk' <<< $BLOCKCHAIN_INFO) 'BEGIN {printf("%.0f\n", size / 1000000)}') MB
    Block Height:           $BLOCK_HEIGHT
    Last Block Minted:      $(awk -v time=$(date +%s) -v blk_time=$(jq '.time' <<< $BLOCKCHAIN_INFO) 'BEGIN {printf("%.2f\n", (time - blk_time) / 60)}') Minutes Ago

    Difficulty:             $(jq '.difficulty' <<< $BLOCKCHAIN_INFO)
    Hashrate:               $(awk -v difficulty=$(jq '.difficulty' <<< $BLOCKCHAIN_INFO) -v blk_interval=$BLOCKINTERVAL 'BEGIN {printf("%.3f\n",  difficulty * 2^32 / blk_interval / 1000000000000)}') TH/s
    Avg. Mint Time:         $(awk -v start=$($BTC getblockstats $BLOCK_HEIGHT | jq '.mediantime') -v end=$($BTC getblockstats $(($BLOCK_HEIGHT - 60)) | jq '.mediantime') 'BEGIN {printf("%.2f\n", (start - end) / 3600)}') Minutes (last 60 blocks)

    Halving Date:           $(date -d @$(awk -v height=$BLOCK_HEIGHT -v halving_interval=$HALVINGINTERVAL -v blk_interval=$BLOCKINTERVAL -v time=$(date +%s) 'BEGIN {printf("%.0f\n", (halving_interval - (height % halving_interval)) * blk_interval + time)}') '+%b %d %Y')

    Block Subisdy:          $(awk -v subsidy=$($BTC getblockstats $BLOCK_HEIGHT | jq '.subsidy') 'BEGIN {printf("%.8f\n", subsidy / 100000000)}') coins
EOF
    echo ""

elif [[ $1 = "--mempool" ]]; then # Show mempool stats
    echo ""
    echo -n "    TX Count:      "; $BTC getmempoolinfo | jq '.size'
    echo -n "    Size (bytes):  "; $BTC getmempoolinfo | jq '.bytes'

    FALL_BACK_FEE=$(sudo cat /etc/bitcoin.conf | grep "fallbackfee" | tr -d "fallbackfee=")
    echo "    Fee Rates         coins/kB              Average Total Fee (coins)"
        FEERATE=$($BTC estimatesmartfee 1 conservative | jq '.feerate')
        if [[ $FEERATE == "null" ]]; then FEERATE=$FALL_BACK_FEE; fi
        echo "        NOW:          $FEERATE                $(awk -v rate=$FEERATE 'BEGIN {printf("%.8f\n", rate * 0.4)}')"

        FEERATE=$($BTC estimatesmartfee 12 economical | jq '.feerate')
        if [[ $FEERATE == "null" ]]; then FEERATE=$FALL_BACK_FEE; fi
        echo "        NORMAL:       $FEERATE                $(awk -v rate=$FEERATE 'BEGIN {printf("%.8f\n", rate * 0.4)}')"

        FEERATE=$($BTC estimatesmartfee 144 economical | jq '.feerate')
        if [[ $FEERATE == "null" ]]; then FEERATE=$FALL_BACK_FEE; fi
        echo "        ECONOMICAL:   $FEERATE                $(awk -v rate=$FEERATE 'BEGIN {printf("%.8f\n", rate * 0.4)}')"

        FEERATE=$($BTC estimatesmartfee 1008 economical | jq '.feerate')
        if [[ $FEERATE == "null" ]]; then FEERATE=$FALL_BACK_FEE; fi
        echo "        CHEAPSKATE:   $FEERATE                $(awk -v rate=$FEERATE 'BEGIN {printf("%.8f\n", rate * 0.4)}')"
    echo ""

elif [[ $1 = "--network" ]]; then # Show network stats
    if [[ $($BTC getaddednodeinfo | jq '.[0] | .connected') == "true" ]]; then
        echo ""; echo "    YES! You are CONNECTED to the \"Banker\" node"; echo ""
    else
        echo ""; echo "    NO! You are NOT connected!"; echo ""
    fi

else
    echo "Method not found"
    echo "Run script with \"--help\" flag"
    echo "Script Version 0.05"
fi
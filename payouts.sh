#!/bin/bash

# Make sure we are not running as root, but that we have sudo privileges.
if [ "$(id -u)" = "0" ]; then
   echo "This script must NOT be run as root (or with sudo)!"
   exit 1
elif [ "$(sudo -l | grep '(ALL : ALL) ALL' | wc -l)" = 0 ]; then
   echo "You do not have enough sudo privileges!"
   exit 1
fi

# Make sure the send_email routine is installed
if ! command -v /usr/local/sbin/send_email &> /dev/null; then
    echo "Error! The \"send_email\" routine could not be found!" | sudo tee -a $LOG
    echo "Download the script and execute \"./send_email.sh --install\" to install this routine."
    read -p "Press any enter to continue ..."
fi

# Load envrionment variables and then verify
if [[ -f /etc/default/payouts.env && ! ($1 == "-i" || $1 == "--install") ]]; then
    source /etc/default/payouts.env
    if [[ -z $NETWORK || -z $NETWORKPREFIX || -z $DENOMINATION || -z $DENOMINATIONNAME || -z $EXPLORER || -z $INITIALREWARD || -z $EPOCHBLOCKS || -z $HALVINGINTERVAL || -z $HASHESPERCONTRACT || -z $BLOCKINTERVAL || -z $TX_BATCH_SZ || -z $ADMINISTRATOREMAIL ]]; then
        echo ""; echo "Error! Not all variables have proper assignments in the \"/etc/default/payouts.env\" file"
        exit 1;
    fi
elif [[ $1 == "-i" || $1 == "--install" ]]; then echo ""
else
    echo "Error! The \"/etc/default/payouts.env\" environment file does not exist!"
    echo "Run this script with the \"-i\" or \"--install\" parameter."
    exit 1;
fi

# Universal envrionment variables
BTC=$(cat /etc/bash.bashrc | grep "alias btc=" | cut -d "\"" -f 2)
UNLOCK="$BTC -rpcwallet=bank walletpassphrase $(sudo cat /root/passphrase) 600"

# Database Location and development mode
SQ3DBNAME=/var/lib/payouts.db
LOG=/var/log/payout.log
SQ3DBNAME=~/tmp_payouts.db.development # This line is automatically commented out during the --install
if [[ $SQ3DBNAME == *"development"* && ! ($1 == "-i" || $1 == "--install") ]]; then
    LOG=~/log.payout.development
    if [ ! -f ~/tmp_payouts.db.development ]; then sudo cp /var/lib/payouts.db ~/tmp_payouts.db.development; fi
    echo ""; read -p "You are in development mode! Press any enter to continue ..."; echo ""
fi

# See which payouts parameter was passed and execute accordingly
if [[ $1 = "-h" || $1 = "--help" ]]; then # Show all possible paramters
    cat << EOF
    Options:
      -h, --help        Display this help message and exit
      -i, --install     Install this script (payouts) in /usr/local/sbin, sqlite3, the DB if it hasn't been already, and loads available epochs from the blockchain
      -o, --control     Main control for the regular payouts; Run this in cron every 2 to 4 hours
                        Install Example (Every Two Hours): Run "crontab -e" and insert the following line: "0 */2 * * * /usr/local/sbin/payouts -o"
      -e, --epoch       Look for next difficulty epoch and prepare the DB for next round of payouts
      -s, --send        Send the Money
      -c, --confirm     Confirm the sent payouts are confirmed in the blockchain; updates the DB
      -m, --email-prep  Prepare all core customer notification emails for the latest epoch
      -n, --send-email  Sends all the prepared emails in the file "/var/tmp/payout.emails"
      -w, --crawl       Look for opened (previously spent) addresses

----- Generic Database Queries ----------------------------------------------------------------------------------------------
      -d, --dump        Show all the contents of the database
      -a, --accounts    Show all accounts
      -l, --sales       Show all sales; Optional Parameter: TELLER
      -r, --contracts   Show all contracts
      -x, --txs         Show all the transactions associated with the latest payout; Optional Parameter: TELLER
      -p, --payouts     Show all payouts thus far
      -t, --totals      Show total amounts for each contract (identical addresses are combinded)
      -z, --tel-addr    Show all Teller Addresses followed by just the active ones

----- Admin/Root Interface --------------------------------------------------------------------------------------------------
      --add-user        Add a new account
                        Parameters: CONTACT_EMAIL  USER_EMAIL  USER_PHONE**  FIRST_NAME  LAST_NAME*  PREFERRED_NAME*  MASTER_EMAIL*
                            Note*: LAST_NAME, PREFERRED_NAME, and MASTER_EMAIL are options
                            Note**: USER_PHONE is optional if MASTER_EMAIL was provided
      --disable-user    Disable an account (also disables associated contracts, but not the sales)
                        Parameters: USER_EMAIL
      --add-sale        Add a sale
                        Parameters: USER_EMAIL  QTY  (TELLER)
                            Note: The USER_EMAIL is the one paying, but the resulting contracts can be assigned to anyone (i.e. Sales don't have to match Contracts).
                            Note: If TELLER is present (can be anything) then the new addition is directed to the teller_sales table.
      --update-sale     Update sale status
                        Parameters: USER_EMAIL  SALE_ID  STATUS  (TELLER)
                            Note: STATUS  =  0 (Not Paid),  1 (Paid),  2 (Trial Run),  3 (Disabled)
                            Note: If TELLER is present (can be anything) then update is directed to the teller_sales table (Trial Run not available in this table).
      --add-contr       Add a contract
                        Parameters: USER_EMAIL  SALE_ID  QTY  MICRO_ADDRESS
      --deliver-contr   Mark every contract with this address as delivered
                        Parameters: MICRO_ADDRESS
      --disable-contr   Disable a contract
                        Parameters: MICRO_ADDRESS  CONTRACT_ID
                            Note: Set CONTRACT_ID to "0" and all contracts matching MICRO_ADDRESS will be disabled
      --add-teller-addr Add (new) address to teller address book
                        Parameters: EMAIL  MICRO_ADDRESS
                            Note: There can only be one active address at a time per account_id. The active old address (if any) is automatically deprecated.

----- Email -----------------------------------------------------------------------------------------------------------------
      --email-banker-summary    Send summary of tellers to the administrator (Satoshi) and manager (Bitcoin CEO)
      --email-core-customer     Send payout email to "core customer"
                                Parameters: NAME; EMAIL; AMOUNT; TOTAL; HASHRATE; CONTACTPHONE; CONTACTEMAIL; COINVALUESATS;
                                            USDVALUESATS; ADDRESSES; TXIDS; (EMAIL_ADMIN_IF_SET)
      --email-teller-summary    Send summary to a Teller (Level 1) Hub/Node
                                Parameters: EMAIL  (EMAIL_EXECUTIVE)
                                    Note: If "EMAIL_EXECUTIVE" is null (i.e. left blank), The Teller's "EMAIL" receives the summary; otherwise,
                                        the administrator will unless the "EMAIL_EXECUTIVE" is a valid email then that email will receive the summary.
      --email-master-summary    Send sub account(s) summary to a master
                                Parameters: EMAIL  (EMAIL_ADMIN_IF_SET)

    Locations:
      This:                     /usr/local/sbin/payouts
      Email Script:             /usr/local/sbin/send_email
      Market Script:            /usr/local/sbin/market
      Log:                      /var/log/payout.log (~/log.payout.development)
      Data Base:                /var/lib/payouts.db (~/tmp_payouts.db.development)
EOF
elif [[ $1 = "-i" || $1 = "--install" ]]; then # Install this script in /usr/local/sbin, the DB if it hasn't been already, and load available epochs from the blockchain
    # Installing the payouts script
    echo "Installing this script (payouts) in /usr/local/sbin/"
    if [ -f /usr/local/sbin/payouts ]; then
        echo "This script (payouts) already exists in /usr/local/sbin!"
        read -p "Would you like to reinstall it? (y|n): "
        if [[ "${REPLY}" = "y" || "${REPLY}" = "Y" ]]; then
            sudo rm /usr/local/sbin/payouts
        else
            exit 0
        fi
    fi
    sudo cat $0 | sed '/Install this script (payouts)/d' | sed '/SQ3DBNAME=~\/tmp_payouts.db.development/d' | sudo tee /usr/local/sbin/payouts > /dev/null
    sudo sed -i 's/$1 = "-i" || $1 = "--install"/"a" = "b"/' /usr/local/sbin/payouts # Make it so this code won't run again in the newly installed script.
    sudo chmod +x /usr/local/sbin/payouts

    # Create the file with the needed envrionment variables if it has not been done already
    if [ ! -f /etc/default/payouts.env ]; then
        read -p "Network Name (e.g. AZ Money): "; echo "NETWORK=\"$REPLY\"" | sudo tee /etc/default/payouts.env > /dev/null; echo "" | sudo tee -a /etc/default/payouts.env > /dev/null

        read -p "Clarifying comment to highlight the commonality between the \"network name\" and the \"microcurrency name\" (e.g. Deseret Money and UT Money): "; echo "CLARIFY=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Network Prefix (e.g. AZ): "; echo "NETWORKPREFIX=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Denomination (e.g. SAGZ): "; echo "DENOMINATION=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Denomination Name (e.g. saguaros): "; echo "DENOMINATIONNAME=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Microcurrency Block Explorer (e.g. <a href=https://somemicrocurrency.com/explorer><u>Some microcurrency Explorer</u></a>): "; echo "EXPLORER=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null; echo "" | sudo tee -a /etc/default/payouts.env > /dev/null

        read -p "Initial block subsidy (e.g. 1500000000): "; echo "INITIALREWARD=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null; INITIALREWARD=$REPLY
        read -p "Number of blocks before each difficulty adjustment (e.g. 1440): "; echo "EPOCHBLOCKS=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Number of blocks in each halving (e.g. 262800): "; echo "HALVINGINTERVAL=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Hashes per second for each contract (e.g. 10000000000): "; echo "HASHESPERCONTRACT=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Teller's bulk purchase size (e.g. 10): "; echo "TELLERBULKPURCHASE=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Number of seconds (typically) between blocks (e.g. 120): "; echo "BLOCKINTERVAL=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Max number of payout periods for this microcurrency (e.g. 910): "; echo "MAX_EPOCH_PERIOD=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null; echo "" | sudo tee -a /etc/default/payouts.env > /dev/null

        read -p "Number of outputs for each send transaction (e.g. 10): "; echo "TX_BATCH_SZ=$REPLY" | sudo tee -a /etc/default/payouts.env > /dev/null; echo "" | sudo tee -a /etc/default/payouts.env > /dev/null

        read -p "Administrator email (e.g. your_email@somedomain.com): "; echo "ADMINISTRATOREMAIL=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
        read -p "Manager email (e.g. friends_email@somedomain.com): "; echo "MANAGER_EMAIL=\"$REPLY\"" | sudo tee -a /etc/default/payouts.env > /dev/null
    else
        echo "The environment file \"/etc/default/payouts.env\" already exits."
    fi

    SQ3DBNAME=/var/lib/payouts.db # Make sure it using the production (not the development) database
    if [ -f "$SQ3DBNAME" ]; then echo "The database \"$SQ3DBNAME\" already exits."; exit 0; fi # Exit! As we do not want to accidentally overwrite our database!

    sudo apt-get -y install sqlite3

    sudo sqlite3 $SQ3DBNAME << EOF
    CREATE TABLE accounts (
        account_id INTEGER PRIMARY KEY,
        master INTEGER,
        contact INTEGER NOT NULL,
        first_name TEXT NOT NULL,
        last_name TEXT,
        preferred_name TEXT,
        email TEXT NOT NULL UNIQUE,
        phone TEXT,
        disabled INTEGER); /* FALSE = 0 or NULL; TRUE = 1 */
    CREATE TABLE sales (
        sale_id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL, /* This is who is/was accountable for the payment; it may vary from the account_id on the corresponding contracts. */
        time INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        status INTEGER, /* NOT_PAID = 0 or NULL; PAID = 1; TRIAL = 2; DISABLED = 3 */
        FOREIGN KEY (account_id) REFERENCES accounts (account_id) ON DELETE CASCADE);
    CREATE TABLE contracts (
        contract_id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL,
        sale_id INTEGER,
        quantity INTEGER NOT NULL,
        time INTEGER NOT NULL,
        active INTEGER, /* Deprecated = 0; Active = 1 or NULL; Opened = 2 */
        delivered INTEGER, /* NO = 0 or NULL; YES = 1 */
        micro_address TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (account_id) ON DELETE CASCADE,
        FOREIGN KEY (sale_id) REFERENCES sales (sale_id) ON DELETE CASCADE);
    CREATE TABLE payouts (
        epoch_period INTEGER PRIMARY KEY,
        block_height INTEGER NOT NULL,
        subsidy INTEGER NOT NULL,
        total_fees INTEGER NOT NULL,
        block_time INTEGER NOT NULL,
        difficulty REAL NOT NULL,
        amount INTEGER NOT NULL,
        notified INTEGER, /* Have the emails been prepared for the core customers? FALSE = 0 or NULL; TRUE = 1*/
        satrate INTEGER);
    CREATE TABLE txs (
        tx_id INTEGER PRIMARY KEY,
        contract_id INTEGER NOT NULL,
        epoch_period INTEGER NOT NULL,
        txid BLOB,
        vout INTEGER,
        amount INTEGER NOT NULL,
        block_height INTEGER,
        FOREIGN KEY (contract_id) REFERENCES contracts (contract_id),
        FOREIGN KEY (epoch_period) REFERENCES payouts (epoch_period));
    CREATE TABLE teller_sales (
        sale_id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL, /* This is who is/was accountable for the payment. Unlike the core customer contracts table, the contracts are always assigned to the purchaser. */
        time INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        status INTEGER, /* NOT_PAID = 0 or NULL; PAID = 1; DISABLED = 3 */
        FOREIGN KEY (account_id) REFERENCES accounts (account_id) ON DELETE CASCADE);
    CREATE TABLE teller_address_book (
        address_id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL, /* Unlike the core customer contracts table, the contracts are always assigned to the purchaser. */
        time INTEGER NOT NULL,
        active INTEGER, /* Deprecated = 0; Active = 1 or NULL*/
        micro_address TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (account_id) ON DELETE CASCADE);
    CREATE TABLE teller_txs (
        tx_id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL,
        epoch_period INTEGER NOT NULL,
        txid BLOB,
        vout INTEGER,
        amount INTEGER NOT NULL,
        block_height INTEGER,
        FOREIGN KEY (epoch_period) REFERENCES payouts (epoch_period),
        FOREIGN KEY (account_id) REFERENCES accounts (account_id) ON DELETE CASCADE);
EOF

    # Configure bitcoind's Log Files; Prevents them from Filling up the Partition
    sudo touch /var/log/payout.log
    sudo chown root:root /var/log/payout.log
    sudo chmod 644 /var/log/payout.log
    cat << EOF | sudo tee /etc/logrotate.d/payout
/var/log/payout.log {
$(printf '\t')create 644 root root
$(printf '\t')monthly
$(printf '\t')rotate 6
$(printf '\t')compress
$(printf '\t')delaycompress
$(printf '\t')postrotate
$(printf '\t')endscript
}
EOF

    # Insert payout for genesis block
    source /etc/default/payouts.env # Load the environment variables
    tmp=$($BTC getblock $($BTC getblockhash 0))
    sudo sqlite3 $SQ3DBNAME "INSERT INTO payouts (epoch_period, block_height, subsidy, total_fees, block_time, difficulty, amount, notified, satrate) VALUES (0, 0, $INITIALREWARD, 0, $(echo $tmp | jq '.time'), $(echo $tmp | jq '.difficulty'), 0, 1, NULL);"

    # Load all payout periods thus far
    while [ -z $output ]; do
        NEXTEPOCH=$((1 + $(sqlite3 $SQ3DBNAME "SELECT epoch_period FROM payouts ORDER BY epoch_period DESC LIMIT 1;")))
        BLOCKEPOCH=$((NEXTEPOCH * EPOCHBLOCKS))
        if [ $($BTC getblockcount) -ge $BLOCKEPOCH ]; then # See if there's another epoch to load
            tmp=$($BTC getblock $($BTC getblockhash $BLOCKEPOCH))
            EXPONENT=$(awk -v eblcks=$BLOCKEPOCH -v interval=$HALVINGINTERVAL 'BEGIN {printf("%d\n", eblcks / interval)}')
            SUBSIDY=$(awk -v reward=$INITIALREWARD -v expo=$EXPONENT 'BEGIN {printf("%0.f\n", reward / 2 ^ expo)}')
            sudo sqlite3 $SQ3DBNAME "INSERT INTO payouts (epoch_period, block_height, subsidy, total_fees, block_time, difficulty, amount) VALUES ($NEXTEPOCH, $BLOCKEPOCH, $SUBSIDY, 0, $(echo $tmp | jq '.time'), $(echo $tmp | jq '.difficulty'), 0)"
        else
            sudo sqlite3 $SQ3DBNAME "UPDATE payouts SET amount = 0, notified = 1" # Set all payout amounts to 0 and notified flag to 1
            exit 0
        fi
        echo "Epoch period number $NEXTEPOCH has been loaded into the payout table"
    done

elif [[ $1 = "-o" || $1 = "--control" ]]; then # Main control for the regular payouts; Run this in cron every 2 to 4 hours
    # Process next epoch period if it has arrived
    NEXTEPOCH=$((1 + $(sqlite3 $SQ3DBNAME "SELECT epoch_period FROM payouts ORDER BY epoch_period DESC LIMIT 1;")))
    BLOCKEPOCH=$((NEXTEPOCH * EPOCHBLOCKS))
    if [[ $($BTC getblockcount) -ge $BLOCKEPOCH ]]; then
        $0 -w # Scan for any opened (spent) addresses
        $0 -e
    fi

    # Send out prepared transactions if any (then exit)
    peek1=$(sqlite3 $SQ3DBNAME "SELECT SUM(amount) FROM txs WHERE txid IS NULL")
    peek2=$(sqlite3 $SQ3DBNAME "SELECT SUM(amount) FROM teller_txs WHERE txid IS NULL")
    if [[ ! -z $peek1 || ! -z $peek2 ]]; then
        $0 -s &
        exit
    fi

    # Verify transactions have been confirmed on the blockchain (then exit)
    peek=$(sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM txs WHERE block_height IS NULL AND txid IS NOT NULL"; sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM teller_txs WHERE block_height IS NULL AND txid IS NOT NULL")
    if [[ ! -z $peek ]]; then
        $0 -c
        exit
    fi

    # Prepare the emails
    $0 -m

    # Send out emails (between 12:00PM and 10:00PM only!)
    TIME=$((10#$(date '+%H%M%S'))) # Force base-10 interpretations; constants with a leading 0 are interpreted as octal numbers.
    if [[ $TIME -ge 120000 && $TIME -le 220000 ]]; then
        $0 -n &
    fi

elif [[ $1 = "-e" || $1 = "--epoch" ]]; then # Look for next difficulty epoch and prepare the DB for next round of payouts
    NEXTEPOCH=$((1 + $(sqlite3 $SQ3DBNAME "SELECT epoch_period FROM payouts ORDER BY epoch_period DESC LIMIT 1;")))
    BLOCKEPOCH=$((NEXTEPOCH * EPOCHBLOCKS))

    if [ $($BTC getblockcount) -ge $BLOCKEPOCH ]; then # See if it is time for the next payout
        # Find total fees for the epoch period
        TOTAL_FEES=0; TX_COUNT=0; TOTAL_WEIGHT=0; MAXFEERATE=0
        for ((i = $(($BLOCKEPOCH - $EPOCHBLOCKS)); i < $BLOCKEPOCH; i++)); do
            tmp=$($BTC getblockstats $i)
            TOTAL_FEES=$(($TOTAL_FEES + $(echo $tmp | jq '.totalfee')))
            TX_COUNT=$(($TX_COUNT + $(echo $tmp | jq '.txs') - 1))
            TOTAL_WEIGHT=$(($TOTAL_WEIGHT + $(echo $tmp | jq '.total_weight')))
            if [ $MAXFEERATE -lt $(echo $tmp | jq '.maxfeerate') ]; then
                MAXFEERATE=$(echo $tmp | jq '.maxfeerate')
            fi
            echo "BLOCK: $i, TOTAL_FEES: $TOTAL_FEES, TX_COUNT: $TX_COUNT, TOTAL_WEIGHT: $TOTAL_WEIGHT, MAXFEERATE: $MAXFEERATE"
        done
        echo "$(date) - Fee calculation complete for next epoch (Number $NEXTEPOCH) - TOTAL_FEES: $TOTAL_FEES, TX_COUNT: $TX_COUNT, TOTAL_WEIGHT: $TOTAL_WEIGHT, MAXFEERATE: $MAXFEERATE" | sudo tee -a $LOG

        # Get details (time and difficulty) of the epoch block
        tmp=$($BTC getblock $($BTC getblockhash $BLOCKEPOCH))
        BLOCKTIME=$(echo $tmp | jq '.time')
        DIFFICULTY=$(echo $tmp | jq '.difficulty')

        # Calculate subsidy
        EXPONENT=$(awk -v eblcks=$BLOCKEPOCH -v interval=$HALVINGINTERVAL 'BEGIN {printf("%d\n", eblcks / interval)}')
        SUBSIDY=$(awk -v reward=$INITIALREWARD -v expo=$EXPONENT 'BEGIN {printf("%0.f\n", reward / 2 ^ expo)}')

        # Calculate payout amount
        AMOUNT=$(awk -v hashrate=$HASHESPERCONTRACT -v btime=$BLOCKINTERVAL -v subs=$SUBSIDY -v totalfee=$TOTAL_FEES -v diff=$DIFFICULTY -v eblcks=$EPOCHBLOCKS 'BEGIN {printf("%0.f\n", ((hashrate * btime) / (diff * 2^32)) * ((subs * eblcks) + totalfee))}')

        # Get array of contract_ids (from active contracts only before this epoch).
        tmp=$(sqlite3 $SQ3DBNAME "SELECT contract_id, quantity FROM contracts WHERE active != 0 AND time<=$BLOCKTIME")
        eol=$'\n'; read -a query <<< ${tmp//$eol/ }

        # Create individual arrays for each column
        read -a CONTIDS <<< ${query[*]%|*}
        read -a QTYS <<< ${query[*]#*|}

        # Prepare values to INSERT into the sqlite db.
        SQL_VALUES=""
        for ((i=0; i<${#QTYS[@]}; i++)); do
            OUTPUT=$(awk -v qty=${QTYS[i]} -v amnt=$AMOUNT 'BEGIN {printf("%0.f\n", (qty * amnt))}')
            SQL_VALUES="$SQL_VALUES(${CONTIDS[i]}, $NEXTEPOCH, $OUTPUT),"
        done
        SQL_VALUES="${SQL_VALUES%?}"

        # Produce an array of the total amount of contracts PURCHASED by each teller (exclude tellers without a payout address)
        tmp=$(sqlite3 $SQ3DBNAME "SELECT account_id, SUM(quantity) FROM teller_sales WHERE status != 3 AND EXISTS(SELECT * FROM teller_address_book sub WHERE active = 1 AND account_id = teller_sales.account_id) GROUP BY account_id")
        eol=$'\n'; read -a arr_purchased  <<< ${tmp//$eol/ }
        read -a ARR_ACCOUNT_IDS <<< ${arr_purchased[*]%|*}
        read -a ARR_QTY_PURCHASED <<< ${arr_purchased[*]#*|}

        # Prepare teller values to inserted into the DB
        SQL_TELLER_VALUES=""
        qty_teller_contracts=0 # Prepare to tally the total amount of (unused) teller contracts across all accounts
        for ((i=0; i<${#ARR_ACCOUNT_IDS[@]}; i++)); do
            SOLD=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM contracts WHERE active = 1 AND EXISTS(SELECT * FROM accounts sub WHERE account_id = contracts.account_id AND contact = ${ARR_ACCOUNT_IDS[i]})")
            if [[ ${ARR_QTY_PURCHASED[i]} -gt $SOLD ]]; then # Make sure they are not all sold out
                OUTPUT=$(awk -v qty=${ARR_QTY_PURCHASED[i]} -v sold=$SOLD -v amnt=$AMOUNT 'BEGIN {printf("%0.f\n", ((qty - sold) * amnt))}')
                SQL_TELLER_VALUES="$SQL_TELLER_VALUES(${ARR_ACCOUNT_IDS[i]}, $NEXTEPOCH, $OUTPUT),"
                qty_teller_contracts=$((qty_teller_contracts + ARR_QTY_PURCHASED[i] - SOLD))
            fi
        done
        if [[ ! -z $SQL_TELLER_VALUES ]]; then SQL_TELLER_VALUES="INSERT INTO teller_txs (account_id, epoch_period, amount) VALUES ${SQL_TELLER_VALUES%?};"; fi # Notice: "${SQL_TELLER_VALUES%?}" removes the last character (',')

        # Insert into database
        echo "$(date) - Attempting to insert next epoch (Number $NEXTEPOCH) into DB" | sudo tee -a $LOG
        sudo sqlite3 -bail $SQ3DBNAME << EOF
        BEGIN transaction;
        PRAGMA foreign_keys = ON;
        INSERT INTO payouts (epoch_period, block_height, subsidy, total_fees, block_time, difficulty, amount)
        VALUES ($NEXTEPOCH, $BLOCKEPOCH, $SUBSIDY, $TOTAL_FEES, $BLOCKTIME, $DIFFICULTY, $AMOUNT);
        INSERT INTO txs (contract_id, epoch_period, amount)
        VALUES $SQL_VALUES;
        COMMIT;
        $SQL_TELLER_VALUES
EOF

        # Query DB
        echo ""; sqlite3 $SQ3DBNAME ".mode columns" "SELECT epoch_period, block_height, subsidy, total_fees, block_time, difficulty, amount FROM payouts WHERE epoch_period = $NEXTEPOCH"
        echo ""; sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM teller_txs WHERE epoch_period = $NEXTEPOCH"
        echo ""; sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM txs WHERE epoch_period = $NEXTEPOCH"; echo ""
        t_payout=$(sqlite3 -separator '; ' $SQ3DBNAME "SELECT 'Epoch Period: ' || epoch_period, 'Epoch Block: ' || block_height, 'Block Time: ' || datetime(block_time, 'unixepoch', 'localtime') as dates, 'Difficulty: ' || difficulty, 'Payout: ' || printf('%.8f', (CAST(amount AS REAL) / 100000000)), 'Subsidy: ' || printf('%.8f', (CAST(subsidy AS REAL) / 100000000)), 'Blocks: ' || (block_height - $EPOCHBLOCKS) || ' - ' || (block_height - 1), 'Total Fees: ' || printf('%.8f', (CAST(total_fees AS REAL) / 100000000)) FROM payouts WHERE epoch_period = $NEXTEPOCH")
        payout_amount=$(sqlite3 $SQ3DBNAME "SELECT amount FROM payouts WHERE epoch_period = $NEXTEPOCH")
        qty_contracts=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM contracts WHERE active != 0 AND time<=$BLOCKTIME")
            #qty_teller_contracts # Calculated above
        qty_utxo=$(($(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM txs WHERE epoch_period = $NEXTEPOCH") + $(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM teller_txs WHERE epoch_period = $NEXTEPOCH")))
        total_payment=$(sqlite3 $SQ3DBNAME "SELECT printf('%.8f', (CAST(SUM(amount) AS REAL) / 100000000)) FROM txs WHERE epoch_period = $NEXTEPOCH")
        total_teller_payment=$(sqlite3 $SQ3DBNAME "SELECT printf('%.8f', (CAST(SUM(amount) AS REAL) / 100000000)) FROM teller_txs WHERE epoch_period = $NEXTEPOCH")
        total=$(awk -v total_1=$total_payment -v total_2=$total_teller_payment 'BEGIN {printf("%.8f\n", total_1 + total_2)}')

        # Log Results
        expected_payment=$(awk -v qty=$qty_contracts -v amount=$payout_amount 'BEGIN {printf("%.8f\n", qty * amount / 100000000)}')
        expected_teller_payment=$(awk -v qty=$qty_teller_contracts -v amount=$payout_amount 'BEGIN {printf("%.8f\n", qty * amount / 100000000)}')
        expected=$(awk -v total_1=$expected_payment -v total_2=$expected_teller_payment 'BEGIN {printf("%.8f\n", total_1 + total_2)}')
        ENTRY="$(date) - New Epoch (Number $NEXTEPOCH)!"$'\n'
        ENTRY="$ENTRY    Fee Results:"$'\n'
        ENTRY="$ENTRY        Total Fees: $TOTAL_FEES"$'\n'
        ENTRY="$ENTRY        TX Count: $TX_COUNT"$'\n'
        ENTRY="$ENTRY        Total Weight: $TOTAL_WEIGHT"$'\n'
        ENTRY="$ENTRY        Max Fee Rate: $MAXFEERATE"$'\n'
        ENTRY="$ENTRY    DB Query (payouts table)"$'\n'
        ENTRY="$ENTRY        $t_payout"$'\n'
        ENTRY="$ENTRY    UTXOs QTY: $qty_utxo"$'\n'
        ENTRY="$ENTRY    Expected Payment: $expected"$'\n'
        ENTRY="$ENTRY    Total Payment: $total"
        echo "$ENTRY" | sudo tee -a $LOG

        # Send Email
        fee_percent_diff=$(awk -v fee=$TOTAL_FEES -v payment=$total_payment 'BEGIN {printf("%.6f\n", ((fee / 100000000) / payment) * 100)}')
        bank_balance=$($BTC -rpcwallet=bank getbalance)
        t_payout="${t_payout//; /<br>}"
        MESSAGE=$(cat << EOF
            <b><u>$(date) - New Epoch (Number $NEXTEPOCH)</u></b><br><br>

            <b>Fee Results:</b><br>
            <ul>
                <li><b>Total Fees:</b> $TOTAL_FEES</li>
                <li><b>TX Count:</b> $TX_COUNT</li>
                <li><b>Total Weight:</b> $TOTAL_WEIGHT</li>
                <li><b>Max Fee Rate:</b> $MAXFEERATE</li>
            </ul><br>

            <b>DB Query (payouts table)</b><br>
            $t_payout<br><br>

            <b>UTXOs QTY:</b> $qty_utxo<br>
            <b>Expected Payment:</b> $expected<br>
            <b>Total Payment:</b> $total<br><br>

            There was a <b>${fee_percent_diff} percent</b> effect upon the total payout from the tx fees collected.<br>
            Note: If this percent ever gets significantly and repeatedly large, there may be some bad players in the network gaming the system.<br><br>

            <b>Wallet (bank) Balance:</b> $bank_balance
EOF
        )
        /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "New Epoch Has Been Delivered" "$MESSAGE"

    else
        echo "$(date) - You have $(($BLOCKEPOCH - $($BTC getblockcount))) blocks to go for the next epoch (Number $NEXTEPOCH)" | sudo tee -a $LOG
    fi

elif [[ $1 = "-s" || $1 = "--send" ]]; then # Send the Money
    # See if error flag is present
    if [ -f /etc/send_payments_error_flag ]; then
        echo "$(date) - The \"--send\" payout routine was halted!" | sudo tee -a $LOG
        echo "    There was a serious error sending out payments last time." | sudo tee -a $LOG
        echo "    Hope you figured out why and was able to resolve it!" | sudo tee -a $LOG
        echo "    Remove file /etc/send_payments_error_flag for this routine to run again." | sudo tee -a $LOG
        exit 1
    fi

    # If there are no payments to process then just exit
    total_payment=$(sqlite3 $SQ3DBNAME "SELECT SUM(amount) FROM txs WHERE txid IS NULL")
    if [ -z $total_payment ]; then
        total_payment=$(sqlite3 $SQ3DBNAME "SELECT SUM(amount) FROM teller_txs WHERE txid IS NULL")
        if [ -z $total_payment ]; then
            echo "$(date) - There are currently no payments to process." | sudo tee -a $LOG
            exit 0
        fi
    else
        tmp_teller=$(sqlite3 $SQ3DBNAME "SELECT SUM(amount) FROM teller_txs WHERE txid IS NULL")
        if [ ! -z $tmp_teller ]; then
            total_payment=$((total_payment + tmp_teller))
        fi
    fi

    # Find out if there is enough money in the bank to execute payments
    bank_balance=$(awk -v balance=$($BTC -rpcwallet=bank getbalance) 'BEGIN {printf("%.0f\n", balance * 100000000)}')
    if [ $((total_payment + 100000000)) -gt $bank_balance ]; then
        message="$(date) - Not enough money in the bank to send payouts! The bank has $bank_balance $DENOMINATION, but it needs $((total_payment + 100000000)) $DENOMINATION before any payouts will be sent."
        echo $message | sudo tee -a $LOG
        /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Not Enough Money in The Bank" "$message"
    fi

    # Query db for tx_id, address, and amount - preparation to send out first set of payments
    tmp=$(sqlite3 $SQ3DBNAME "SELECT txs.tx_id, contracts.micro_address, txs.amount FROM contracts, txs WHERE contracts.contract_id = txs.contract_id AND txs.txid IS NULL LIMIT $TX_BATCH_SZ")
    eol=$'\n'; read -a query <<< ${tmp//$eol/ }
    total_sending=0
    start_time=$(date +%s)
    table="txs" # Will be working on the "txs" table initially then the "teller_txs" afterwards
    while [ ! -z "${tmp}" ]; do
        count=$(($(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM txs WHERE txid IS NULL") + $(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM teller_txs WHERE txid IS NULL"))) # Get the total count of utxos to be generated
        echo "There are $count UTXOs left to be generated and submitted. (Batch Size: $TX_BATCH_SZ UTXOs/TX)"

        # Create individual arrays for each column (database insertion)
        read -a tmp <<< $(echo ${query[*]#*|})
        read -a ADDRESS <<< ${tmp[*]%|*}
        read -a AMOUNT <<< ${query[*]##*|}
        read -a TX_ID <<< ${query[*]%%|*}

        # Prepare outputs for the transactions
        utxos=""
        for ((i=0; i<${#TX_ID[@]}; i++)); do
            total_sending=$((total_sending + AMOUNT[i]))
            txo=$(awk -v amnt=${AMOUNT[i]} 'BEGIN {printf("%.8f\n", (amnt/100000000))}')
            utxos="$utxos\"${ADDRESS[i]}\":$txo,"
        done
        utxos=${utxos%?}

        # Make the transaction
        $UNLOCK
        TXID="" # Clear variable to further prove TXID uniqueness.
        TXID=$($BTC -rpcwallet=bank -named send outputs="{$utxos}" conf_target=10 estimate_mode="economical" | jq '.txid')
        if [[ ! ${TXID//\"/} =~ ^[0-9a-f]{64}$ ]]; then
            echo "$(date) - Serious Error!!! Invalid TXID: $TXID" | sudo tee -a $LOG
            /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Serious Error - Invalid TXID" "An invalid TXID was encountered while sending out payments"
            sudo touch /etc/send_payments_error_flag
            exit 1
        fi
        TX=$($BTC -rpcwallet=bank gettransaction ${TXID//\"/})

        # Update the DB with the TXID and vout
        for ((i=0; i<${#TX_ID[@]}; i++)); do
            sudo sqlite3 $SQ3DBNAME "UPDATE $table SET txid = $TXID, vout = $(echo $TX | jq .details[$i].vout) WHERE tx_id = ${TX_ID[i]};"
        done

        # Make sure the "count" of utxos to be generated is going down
        if [ $count -le $(($(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM txs WHERE txid IS NULL") + $(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM teller_txs WHERE txid IS NULL"))) ]; then
            echo "$(date) - Serious Error!!! Infinite loop while sending out payments!" | sudo tee -a $LOG
            /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Serious Error - Sending Payments Indefinitely" "Infinite loop while sending out payments."
            sudo touch /etc/send_payments_error_flag
            exit 1
        fi

        # Query db for the next tx_id, address, and amount - preparation to officially send out payments for the next iteration of this loop.
        tmp=$(sqlite3 $SQ3DBNAME "SELECT txs.tx_id, contracts.micro_address, txs.amount FROM contracts, txs WHERE contracts.contract_id = txs.contract_id AND txs.txid IS NULL LIMIT $TX_BATCH_SZ")
        table="txs"
        if [ -z "${tmp}" ]; then
            tmp=$(sqlite3 $SQ3DBNAME "SELECT tx_id, (SELECT micro_address FROM teller_address_book sub WHERE active = 1 AND account_id = teller_txs.account_id), amount FROM teller_txs WHERE txid IS NULL LIMIT $TX_BATCH_SZ")
            table="teller_txs" # Now working on the teller txs
        fi
        eol=$'\n'; read -a query <<< ${tmp//$eol/ }
    done
    end_time=$(date +%s)

    # Make sure all payments have been sent!
    if [ 0 -lt $(($(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM txs WHERE txid IS NULL") + $(sqlite3 $SQ3DBNAME "SELECT COUNT(*) FROM teller_txs WHERE txid IS NULL"))) ]; then
        echo "$(date) - Serious Error!!! Unfulfilled TXs in the DB after sending payments!" | sudo tee -a $LOG
        /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Serious Error - Unfulfilled TXs" "Unfulfilled TXs in the DB after sending payments."
        sudo touch /etc/send_payments_error_flag
        exit 1
    fi

    # Log Results
    post_bank_balance=$($BTC -rpcwallet=bank getbalance)
    bank_balance=$(awk -v num=$bank_balance 'BEGIN {printf("%.8f\n", num / 100000000)}')
    total_payment=$(awk -v num=$total_payment 'BEGIN {printf("%.8f\n", num / 100000000)}')
    total_sending=$(awk -v num=$total_sending 'BEGIN {printf("%.8f\n", num / 100000000)}')
    ENTRY="$(date) - All Payments have been completed successfully!"$'\n'
    ENTRY="$ENTRY    Execution Time: $((end_time - start_time)) seconds."$'\n'
    ENTRY="$ENTRY    Outputs Per TX: $TX_BATCH_SZ"$'\n'
    ENTRY="$ENTRY    Bank Balance: $bank_balance (Before Sending Payments)"$'\n'
    ENTRY="$ENTRY    Calculated Total: $total_payment"$'\n'
    ENTRY="$ENTRY    Total Sent: $total_sending"$'\n'
    ENTRY="$ENTRY    Bank Balance: $post_bank_balance (After Sending Payments + TX Fees)"
    echo "$ENTRY" | sudo tee -a $LOG

    # Send Email
    t_txids=$(sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM txs WHERE block_height IS NULL AND txid IS NOT NULL")
    t_txids="${t_txids}<br>$(sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM teller_txs WHERE block_height IS NULL AND txid IS NOT NULL;")"
    eol=$'\n'; t_txids=${t_txids//$eol/<br>}
    time=$((end_time - start_time))
    MESSAGE=$(cat << EOF
        <b>$(date) - All Payments have been completed successfully</b><br>
        <ul>
            <li><b>Execution Time:</b> $time seconds</li>
            <li><b>Outputs Per TX:</b> $TX_BATCH_SZ</li>
            <li><b>Bank Balance:</b> $bank_balance (Before Sending Payments)</li>
            <li><b>Calculated Total:</b> $total_payment</li>
            <li><b>Total Sent:</b> $total_sending</li>
            <li><b>Bank Balance:</b> $post_bank_balance (After Sending Payments + TX Fees)</li>
        </ul><br>

        <b>DB Query (All Recent TXIDs)</b><br>
        $t_txids
EOF
    )
    /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "All Payments have been completed successfully" "$MESSAGE"

elif [[ $1 = "-c" || $1 = "--confirm" ]]; then # Confirm the sent payouts are confirmed in the blockchain; update the DB
    # Get all the txs (including teller_txs) that have a valid TXID without a block height
    tmp=$(sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM txs WHERE block_height IS NULL AND txid IS NOT NULL"; sqlite3 $SQ3DBNAME "SELECT DISTINCT txid FROM teller_txs WHERE block_height IS NULL AND txid IS NOT NULL")
    eol=$'\n'; read -a query <<< ${tmp//$eol/ }

    if [ -z "${tmp}" ]; then
        echo "All transactions have been successfully confirmed on the blockchain."
        exit 0
    fi

    # See if each TXID has at least 6 confirmations; if so, update the block height in the DB.
    confirmed=0
    for ((i=0; i<${#query[@]}; i++)); do
        tmp=$($BTC -rpcwallet=bank gettransaction ${query[i]})

        CONFIRMATIONS=$(echo $tmp | jq '.confirmations')
        if [ $CONFIRMATIONS -ge "6" ]; then
            sudo sqlite3 $SQ3DBNAME "UPDATE txs SET block_height = $(echo $tmp | jq '.blockheight') WHERE txid = \"${query[i]}\""
            sudo sqlite3 $SQ3DBNAME "UPDATE teller_txs SET block_height = $(echo $tmp | jq '.blockheight') WHERE txid = \"${query[i]}\""
            confirmed=$((confirmed + 1))

            # Query DB
            echo "Confirmed:"
            sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM txs WHERE txid = \"${query[i]}\""
            sqlite3 $SQ3DBNAME ".mode columns" "SELECT tx_id AS 'Teller TXs', * FROM teller_txs WHERE txid = \"${query[i]}\""
            echo ""
        else
            echo "NOT Confirmed! TXID \"${query[i]}\" has $CONFIRMATIONS confirmations (needs 6 or more)."; echo ""
        fi
    done

    # Log and Email
    if [ "$confirmed" = "0" ]; then # Simplify the log input (with no email) if there are no new confirmations.
        echo "$(date) - ${#query[@]} transaction(s) is/are still waiting to be confirmed on the blockchain with 6 or more confirmations." | sudo tee -a $LOG
    else
        echo "$(date) - ${confirmed} transaction(s) was/were confirmed on the blockchain with 6 or more confirmations." | sudo tee -a $LOG
        echo "    $((${#query[@]} - confirmed)) transaction(s) is/are still waiting to be confirmed on the blockchain with 6 or more confirmations." | sudo tee -a $LOG

        message="$(date) - ${confirmed} transaction(s) was/were confirmed on the blockchain with 6 or more confirmations.<br><br>"
        message="${message} $((${#query[@]} - confirmed)) transaction(s) is/are still waiting to be confirmed on the blockchain with 6 or more confirmations."

        /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Confirming Transaction(s) on The Blockchain" "$message"
    fi

elif [[ $1 = "-m" || $1 = "--email-prep" ]]; then # Prepare all core customer notification emails for the latest epoch
    # Check to see if the latest epoch has already been "notified"
    notified=$(sqlite3 $SQ3DBNAME "SELECT notified FROM payouts WHERE epoch_period = (SELECT MAX(epoch_period) FROM payouts)")
    if [ ! -z $notified ]; then
        echo "No emails to prepare at this time!"
        exit 0
    fi

    # Generate payout data to be sent to each core customer
    tmp=$(sqlite3 $SQ3DBNAME << EOF
    SELECT
        accounts.account_id,
        (CASE WHEN accounts.preferred_name IS NULL THEN accounts.first_name ELSE accounts.preferred_name END),
        accounts.email,
        CAST(SUM(txs.amount) AS REAL) / 100000000,
        (SELECT CAST(SUM(amount) AS REAL) / 100000000
            FROM txs, contracts
            WHERE txs.contract_id = contracts.contract_id AND accounts.account_id = contracts.account_id),
        SUM(contracts.quantity) * $HASHESPERCONTRACT / 1000000000,
        (SELECT phone FROM accounts sub WHERE sub.account_id = accounts.contact),
        (SELECT email FROM accounts sub WHERE sub.account_id = accounts.contact)
    FROM accounts, txs, contracts
    WHERE accounts.account_id = contracts.account_id AND contracts.contract_id = txs.contract_id AND txs.epoch_period = (SELECT MAX(epoch_period) FROM payouts)
    GROUP BY accounts.account_id
EOF
    )
    eol=$'\n'; read -a tmp_notify_data <<< ${tmp//$eol/ }

    unset notify_data # Make sure the array is empty
    for ((i=0; i<${#tmp_notify_data[@]}; i++)); do
        notify_data[${tmp_notify_data[i]%%|*}]=${tmp_notify_data[i]#*|}
    done

    # Pivot all addresses associated with each account for this payout ('_' delimiter)
    tmp=$(sqlite3 $SQ3DBNAME << EOF
.separator "_"
    SELECT
        account_id,
        micro_address,
        active
    FROM contracts
    GROUP BY micro_address
EOF
    )
    eol=$'\n'; read -a tmp_addresses <<< ${tmp//$eol/ }

    unset addresses # Make sure the array is empty
    for ((i=0; i<${#tmp_addresses[@]}; i++)); do
        addresses[${tmp_addresses[i]%%_*}]=${addresses[${tmp_addresses[i]%%_*}]}.${tmp_addresses[i]#*_}
    done

    # Pivot all TXIDs ossociated with each account for this payout
    tmp=$(sqlite3 $SQ3DBNAME << EOF
    SELECT
        contracts.account_id,
        txs.txid
    FROM txs, contracts
    WHERE txs.contract_id = contracts.contract_id AND txs.epoch_period = (SELECT MAX(epoch_period) FROM payouts)
    GROUP BY contracts.account_id, txs.txid
EOF
    )
    eol=$'\n'; read -a tmp_txids <<< ${tmp//$eol/ }

    unset txids # Make sure the array is empty
    for ((i=0; i<${#tmp_txids[@]}; i++)); do
        txids[${tmp_txids[i]%|*}]=${txids[${tmp_txids[i]%|*}]}.${tmp_txids[i]#*|}
    done

    # Format all the array data togethor for core customer emails and add them to the payout.emails file
    latest_epoch_period=$(sqlite3 $SQ3DBNAME "SELECT MAX(epoch_period) FROM payouts")
    for i in "${!notify_data[@]}"; do
        echo "$0 --email-core-customer ${notify_data[$i]//|/ } \$SATRATE \$USDSATS $latest_epoch_period ${addresses[$i]#*.} ${txids[$i]#*.}" | sudo tee -a /var/tmp/payout.emails
    done

    # Add Master emails to the list (payout.emails)
    tmp=$(sudo sqlite3 $SQ3DBNAME "SELECT email FROM accounts WHERE EXISTS(SELECT * FROM accounts sub WHERE master = accounts.account_id)")
    eol=$'\n'; read -a master_emails <<< ${tmp//$eol/ }
    for i in "${!master_emails[@]}"; do
        echo "$0 --email-master-summary ${master_emails[$i]}" | sudo tee -a /var/tmp/payout.emails
    done

    # Add Teller Summaries-emails to the list (payout.emails)
    tmp=$(sudo sqlite3 $SQ3DBNAME "SELECT email FROM accounts WHERE EXISTS(SELECT * FROM accounts sub WHERE contact = accounts.account_id)")
    eol=$'\n'; read -a contact_emails <<< ${tmp//$eol/ }
    for i in "${!contact_emails[@]}"; do
        echo "$0 --email-teller-summary ${contact_emails[$i]}" | sudo tee -a /var/tmp/payout.emails
    done

    # Add command to send out banker summary on the list (payout.emails)
    echo "$0 --email-banker-summary" | sudo tee -a /var/tmp/payout.emails

    # Set the notified flag
    sudo sqlite3 $SQ3DBNAME "UPDATE payouts SET notified = 1 WHERE notified IS NULL;"

    # Log Results
    echo "$(date) - $(wc -l < /var/tmp/payout.emails) email(s) have been prepared to send to customer(s)." | sudo tee -a $LOG

    # Send Email
    /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Customer Emails Are Ready to Send" "$(wc -l < /var/tmp/payout.emails) email(s) have been prepared to send to customer(s)."

elif [[ $1 = "-n" || $1 = "--send-email" ]]; then # Sends all the prepared emails in the file "/var/tmp/payout.emails"
     # Check if file "payout.emails" exists or if it is empty
    if [ -f /var/tmp/payout.emails ]; then
        if [ ! -s /var/tmp/payout.emails ]; then echo "File \"/var/tmp/payout.emails\" is empty!"; exit; fi # Check if file is empty
    else
        echo "File \"/var/tmp/payout.emails\" did not exist... 'till now!"
        sudo touch /var/tmp/payout.emails
        exit
    fi

    # Get market data
    old_satrate=$(sqlite3 $SQ3DBNAME "SELECT satrate FROM payouts WHERE epoch_period = (SELECT MAX(epoch_period) FROM payouts) - 1")
    SATRATE=$(/usr/local/sbin/market --getmicrorate $old_satrate)
    USDSATS=$(/usr/local/sbin/market --getusdrate)
    if [[ -z $SATRATE || -z $USDSATS ]]; then echo "Error! Could not get market rates!"; exit 1; fi
    sudo sqlite3 $SQ3DBNAME "UPDATE payouts SET satrate = $SATRATE WHERE epoch_period = (SELECT MAX(epoch_period) FROM payouts) AND satrate IS NULL"

    # Sending Emails NOW!!
    echo "$(date) - Sending all the prepared emails right now! Market data: SATRATE=$SATRATE; USDSATS=$USDSATS!" | sudo tee -a $LOG
    /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "SENDING EMAILS NOW!!!" "$(date) - Sending all the prepared emails right now! Market data: SATRATE=$SATRATE; USDSATS=$USDSATS!"
    sudo mv /var/tmp/payout.emails /var/tmp/payout.emails.bak
    sudo touch /var/tmp/payout.emails
    while read -r line; do
        eval "$line"
    done < /var/tmp/payout.emails.bak

elif [[ $1 = "-w" || $1 = "--crawl" ]]; then # Look for opened (previously spent) addresses
    # Load all active (non-opened) addresses from the DB to the Watch wallet
    ADDRESSES=$(sqlite3 $SQ3DBNAME "SELECT '{\"scriptPubKey\":{\"address\":\"' || micro_address || '\"},\"timestamp\":\"now\",\"label\":\"Searching for opened payouts...\"},' FROM contracts WHERE active = 1")
    $BTC -rpcwallet=watch importmulti "[${ADDRESSES%?}]"

    # Rescan the Watch wallet
    echo ""; echo -n "    Scanning the entire blockchain... This could take awhile! "
    while true; do echo -n .; sleep 1; done & # Show user that progress is being made
    $BTC -rpcwallet=watch rescanblockchain > /dev/null
    kill $!; trap 'kill $!' SIGTERM
    echo "done"; echo ""

    # Crawl through all the addresses in the Watch wallet and see if they have been opened (spent from)
    echo ""; echo -n "    Finding all UTXOs for all addresses... This could take awhile! "
    readarray -t RECEIVED < <($BTC -rpcwallet=watch listreceivedbyaddress | jq -r '.[] | .address, (.txids | length)') # Get all the address and the number transactions for each one
    for ((i = 0; i < ${#RECEIVED[@]}; i = i + 2)); do # Go through each address to find the number of UTXOs
        echo -n "."
        utxos=$($BTC -rpcwallet=watch listunspent 0 9999999 "[\"${RECEIVED[i]}\"]" | jq '.[].amount' | awk '{count++} END{printf("%d", count)}')
        if [[ ${RECEIVED[i + 1]} != $utxos ]]; then # If number of UTXOs does not match the number transactions then this address has been used
            sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET active = 2 WHERE micro_address = '${RECEIVED[i]}' AND active = 1" # Mark as opended in the database
            echo "$(date) - Address \"${RECEIVED[i]}\" has been opended (spent from)!" | sudo tee -a $LOG
        fi
    done; echo "done"; echo ""

    echo "$(date) - Crawled the blockchain looking at (${#RECEIVED[@]} / 2) addresses to see if any have been spent (opened)." | sudo tee -a $LOG

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ Generic Database Queries ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
elif [[ $1 = "-d" || $1 = "--dump" ]]; then # Show all the contents of the database
    sqlite3 $SQ3DBNAME ".dump"

elif [[ $1 = "-a" || $1 = "--accounts" ]]; then # Show all accounts
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM accounts"

elif [[ $1 = "-l" || $1 = "--sales" ]]; then # Show all sales
    TELLER=$2

    if [[ -z $TELLER ]]; then
        sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM sales"
        echo ""; echo "Status: NOT_PAID = 0 or NULL; PAID = 1; TRIAL = 2; DISABLED = 3"
        echo ""; echo "Note: The contract owners and contract buyers don't have to match."
        echo "Example: Someone may buy extra contracts for a friend."; echo ""
    else
        sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM teller_sales"
        echo ""; echo "Status: NOT_PAID = 0 or NULL; PAID = 1; DISABLED = 3"; echo ""
    fi

elif [[ $1 = "-r" || $1 = "--contracts" ]]; then # Show all contracts
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts"

elif [[ $1 = "-x" || $1 = "--txs" ]]; then # Show all the transactions associated with the latest payout
    TELLER=$2

    # The latest transactions added to the DB
    if [[ -z $TELLER ]]; then
        sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM txs WHERE epoch_period = (SELECT MAX(epoch_period) FROM payouts);"
    else
        sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM teller_txs WHERE epoch_period = (SELECT MAX(epoch_period) FROM payouts);"
    fi

elif [[ $1 = "-p" || $1 = "--payouts" ]]; then # Show all payouts thus far
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM payouts"

elif [[ $1 = "-t" || $1 = "--totals" ]]; then # Show total amounts for each contract (identical addresses are combinded)
    echo ""
    sqlite3 $SQ3DBNAME << EOF
.mode columns
    SELECT
        accounts.first_name || COALESCE(' (' || accounts.preferred_name || ') ', ' ') || COALESCE(accounts.last_name, '') AS Name,
        contracts.micro_address AS Address,
        CAST(SUM(txs.amount) as REAL) / 100000000 AS Total
    FROM accounts, contracts, txs
    WHERE contracts.contract_id = txs.contract_id AND contracts.account_id = accounts.account_id
    GROUP BY contracts.micro_address
    ORDER BY accounts.account_id;
EOF
    echo ""

elif [[ $1 = "--tel-addr" ]]; then # Show all Teller Addresses followed by just the active ones
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM teller_address_book ORDER BY active"

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ Admin/Root Interface ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
elif [[ $1 = "--add-user" ]]; then # Add a new account
    CONTACT_EMAIL="${2,,}"; USER_EMAIL="${3,,}"; USER_PHONE="${4,,}"; FIRST_NAME="$5"; LAST_NAME=$6; PREFERRED_NAME="${7,,}"; MASTER_EMAIL="${8,,}"

    # Very basic input checking
    if [[ -z $CONTACT_EMAIL || -z $USER_EMAIL || -z $USER_PHONE || -z $FIRST_NAME || -z $LAST_NAME || -z $PREFERRED_NAME || -z $MASTER_EMAIL ]]; then
        echo "Error! Insufficient Parameters!"
        exit 1
    elif [[ $CONTACT_EMAIL == "null" || $USER_EMAIL == "null"  || $FIRST_NAME == "null" ]]; then
        echo "Error! Contact email, user email, and first name are all required!"
        exit 1
    elif [[ $USER_PHONE == "null" && $MASTER_EMAIL == "null" ]]; then # Phone must be present if no "MASTER" is present
        echo "Error! No phone!"
        exit 1
    fi

    # Check for correct formats
    if [[ ! "$USER_EMAIL" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,4}$ ]]; then echo "Error! Invalid Email!"; exit 1; fi
    if [[ ! "$FIRST_NAME" =~ ^[a-zA-Z]+$ ]]; then echo "Error! Invalid First Name!"; exit 1; fi
    if [[ ! "$LAST_NAME" =~ ^[a-zA-Z-]+$ ]]; then echo "Error! Invalid Last Name!"; exit 1; fi
    if [[ ! "$PREFERRED_NAME" =~ ^[a-z]+$ ]]; then echo "Error! Invalid Preferred Name!"; exit 1; fi
    if [[ "$USER_PHONE" != "null" && ! "$USER_PHONE" =~ ^[0-9]{3}-[0-9]{3}-[0-9]{4}$ ]]; then echo "Error! Invalid Phone Number (Format)!"; exit 1; fi

    # Make sure the "Master Email" is present if not null
    if [[ $MASTER_EMAIL != "null" ]]; then
        MASTER=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '$MASTER_EMAIL'") # Get the account_id for the MASTER_EMAIL
        if [[ -z $MASTER ]]; then
            echo "Error! Master email is not in the DB!"
            exit 1
        fi
    else
        MASTER="NULL"
    fi

    # Make sure the "Contact Email" is present
    CONTACT=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '$CONTACT_EMAIL'") # Get the account_id for the CONTACT_EMAIL
    if [[ -z $CONTACT ]]; then
        echo "Error! Contact email is not in the DB!"
        exit 1
    fi

    # Prepare variables that may contain the string "null" for the DB
    if [[ $USER_PHONE == "null" ]]; then USER_PHONE="NULL"; else USER_PHONE="'$USER_PHONE'"; fi
    if [[ $LAST_NAME == "null" ]]; then LAST_NAME="NULL"; else LAST_NAME="'$LAST_NAME'"; fi
    if [[ $PREFERRED_NAME == "null" ]]; then PREFERRED_NAME="NULL"; else PREFERRED_NAME="'${PREFERRED_NAME^}'"; fi

    # Insert into the DB
    sudo sqlite3 $SQ3DBNAME "INSERT INTO accounts (master, contact, first_name, last_name, preferred_name, email, phone, disabled) VALUES ($MASTER, $CONTACT, '${FIRST_NAME^}', $LAST_NAME, $PREFERRED_NAME, '$USER_EMAIL', $USER_PHONE, 0);"

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM accounts WHERE email = '$USER_EMAIL'"

elif [[ $1 = "--disable-user" ]]; then # Disable an account (i.e. marks an account as disabled; it also disables all of the mining contracts pointing to this account)
    USER_EMAIL=$2

    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM accounts WHERE email = '${USER_EMAIL,,}')")
    if [[ $exists == "0" ]]; then
        echo "Error! Email does not exist in the database!"
        exit 1
    fi
    account_id=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '${USER_EMAIL,,}'") # Get the account_id

    # Update the DB
    sudo sqlite3 $SQ3DBNAME "UPDATE accounts SET disabled = 1 WHERE email = '${USER_EMAIL,,}'"
    sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET active = 0 WHERE account_id = $account_id"

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM accounts WHERE email = '${USER_EMAIL,,}'"
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts WHERE account_id = $account_id"

elif [[ $1 = "--add-sale" ]]; then # Add a sale - Note: The User_Email is the one paying, but the resulting contracts can be assigned to anyone
    USER_EMAIL=$2; QTY=$3; TELLER=$4

    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM accounts WHERE email = '${USER_EMAIL,,}')")
    if [[ $exists == "0" ]]; then
        echo "Error! Email does not exist in the database!"
        exit 1
    fi
    if ! [[ $QTY =~ ^[0-9]+$ ]]; then
        echo "Error! Quantity is not a number!";
        exit 1
    fi
    account_id=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '${USER_EMAIL,,}'") # Get the account_id

    # Insert into the DB
    if [[ -z $TELLER ]]; then table="sales"; else table="teller_sales"; fi
    sudo sqlite3 $SQ3DBNAME << EOF
        PRAGMA foreign_keys = ON;
        INSERT INTO $table (account_id, time, quantity, status)
        VALUES ($account_id, $(date +%s), $QTY, 0);
EOF

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM $table WHERE account_id = $account_id"
    SALE_ID=$(sqlite3 $SQ3DBNAME "SELECT sale_id FROM $table WHERE account_id = $account_id ORDER BY sale_id DESC LIMIT 1")
    echo ""; echo "Current Unix Time: $(date +%s)"
    echo "Your new \"Sale ID\": $SALE_ID"; echo ""

elif [[ $1 = "--update-sale" ]]; then # Update sale status
    USER_EMAIL=$2; SALE_ID=$3; STATUS=$4; TELLER=$5

    if ! [[ $SALE_ID =~ ^[0-9]+$ ]]; then echo "Error! \"Sale ID\" is not a number!"; exit 1; fi
    if [[ -z $TELLER ]]; then table="sales"; else table="teller_sales"; fi
    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM $table WHERE account_id = (SELECT account_id FROM accounts WHERE email = '${USER_EMAIL,,}') AND sale_id = $SALE_ID)")
    if [[ $exists == "0" ]]; then
        echo "Error! \"User Email\" with provided \"Sale ID\" does not exist in the database (\"$table\" table)!"
        exit 1
    fi

    if ! [[ $STATUS =~ ^[0-9]+$ ]]; then
        echo "Error! Status code is not a number!";
        exit 1
    elif [[ $STATUS == "0" ]]; then echo "Update to \"Not Paid\""
    elif [[ $STATUS == "1" ]]; then echo "Update to \"Paid\""
    elif [[ $STATUS == "2" && -z $TELLER ]]; then echo "Update to \"Trial Run\""
    elif [[ $STATUS == "3" ]]; then echo "Update to \"Disabled\""; else
        echo "Error! Invalid status code!";
        exit 1
    fi

    # Update the DB
    sudo sqlite3 $SQ3DBNAME "UPDATE $table SET status = $STATUS WHERE sale_id = $SALE_ID"
    if [[ $STATUS == "3" && -z $TELLER ]]; then
        sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET active = 0 WHERE sale_id = $SALE_ID"
    fi

    # Query the DB
    echo ""; sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM $table WHERE sale_id = $SALE_ID"; echo ""
    if [[ $STATUS == "3" && -z $TELLER ]]; then
        sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts WHERE sale_id = $SALE_ID"; echo ""
    fi

elif [[ $1 = "--add-contr" ]]; then # Add a contract
    USER_EMAIL=$2; SALE_ID=$3; QTY=$4; MICRO_ADDRESS=$5

    if ! [[ $SALE_ID =~ ^[0-9]+$ ]]; then echo "Error! \"Sale ID\" is not a number!"; exit 1; fi
    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM sales WHERE sale_id = $SALE_ID)")
    if [[ $exists == "0" ]]; then
        echo "Error! \"Sale ID\" does not exist in the database!"
        exit 1
    fi

    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM accounts WHERE email = '${USER_EMAIL,,}')")
    if [[ $exists == "0" ]]; then
        echo "Error! \"User Email\" does not exist in the database!"
        exit 1
    fi

    if ! [[ $QTY =~ ^[0-9]+$ ]]; then
        echo "Error! Quantity provided is not a number!"
        exit 1
    elif [[ $QTY == "0" ]]; then
        echo "Error! Quantity provided is zero!"
        exit 1
    fi
    total=$(sqlite3 $SQ3DBNAME "SELECT quantity FROM sales WHERE sale_id = $SALE_ID")
    assigned=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM contracts WHERE sale_id = $SALE_ID AND active != 0")
    if [[ ! $QTY -le $((total - assigned)) ]]; then
        echo "Error! The \"Sale ID\" provided cannot accommodate more than $((total - assigned)) \"shares\"!"
        exit 1
    fi

    if ! [[ $($BTC validateaddress ${MICRO_ADDRESS,,} | jq '.isvalid') == "true" ]]; then
        echo "Error! Address provided is not correct or Bitcoin Core (microcurrency mode) is down!"
        exit 1
    fi

    # Insert into the DB
    ACCOUNT_ID=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '${USER_EMAIL,,}'")
    sudo sqlite3 $SQ3DBNAME << EOF
        PRAGMA foreign_keys = ON;
        INSERT INTO contracts (account_id, sale_id, quantity, time, active, delivered, micro_address)
        VALUES ($ACCOUNT_ID, $SALE_ID, $QTY, $(date +%s), 1, 0, '${MICRO_ADDRESS,,}');
EOF

    # If there is a preexisting contract with the same address that is marked "delivered" then mark this delivered!
    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}' AND delivered = 1)")
    if [[ $exists == "1" ]]; then
        $0 --deliver-contr $MICRO_ADDRESS > /dev/null
    fi

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts WHERE account_id = $ACCOUNT_ID"

    # Let's see if the teller needs to make another bulk purchase
    TOTAL=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM teller_sales WHERE status != 3 AND account_id = (SELECT contact FROM accounts WHERE email = '${USER_EMAIL,,}')")
    SOLD=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM contracts WHERE active = 1 AND (SELECT contact FROM accounts WHERE account_id = contracts.account_id) = (SELECT contact FROM accounts WHERE email = '${USER_EMAIL,,}')")
        # NOTE: "$SOLD" is the qty of contracts that have been sold to customers AND allocated with the "--add-contr". Non allocated contracts will not count.
    if [[ $((TOTAL - SOLD)) -lt 0 ]]; then
        NAME=$(sqlite3 $SQ3DBNAME "SELECT (CASE WHEN accounts.preferred_name IS NULL THEN accounts.first_name ELSE accounts.preferred_name END) FROM accounts WHERE account_id = (SELECT contact FROM accounts WHERE email = '${USER_EMAIL,,}')")
        EMAIL=$(sqlite3 $SQ3DBNAME "SELECT email FROM accounts WHERE account_id = (SELECT contact FROM accounts WHERE email = '${USER_EMAIL,,}')")

        # Add bulk (teller) sales
        while [[ $((TOTAL - SOLD)) -lt 0 ]]; do
            $0 --add-sale $EMAIL $TELLERBULKPURCHASE TELLER_SALE
            TOTAL=$(sqlite3 $SQ3DBNAME "SELECT SUM(quantity) FROM teller_sales WHERE status != 3 AND account_id = (SELECT contact FROM accounts WHERE email = '${USER_EMAIL,,}')")
            echo "$(date) - Bulk teller sale was made (automatically) for $NAME ($EMAIL)!" | sudo tee -a $LOG
        done

        # Send email
        /usr/local/sbin/send_email "$NAME" "$EMAIL" "Bulk Hash Rate Purchase" "Hi $NAME,<br><br>Congratulations!!! You have purchased (automatically) some more hash rate (in bulk) to cover all your core customers!<br><br>At your convienence, negotiate payment (in SATS please) with your Lvl2 (Banker) Hub"
    fi

elif [[ $1 = "--deliver-contr" ]]; then # Mark a contract as delivered
    MICRO_ADDRESS=$2

    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}')")
    if [[ $exists == "0" ]]; then
        echo "Error! The \"Microcurrency Address\" provided does not exist in the database!"
        exit 1
    fi

    # Update the DB
    sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET delivered = 1 WHERE micro_address = '${MICRO_ADDRESS,,}'"

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}'"

elif [[ $1 = "--disable-contr" ]]; then # Disable a contract
    MICRO_ADDRESS=$2; CONTRACT_ID=$3

    if ! [[ $CONTRACT_ID =~ ^[0-9]+$ ]]; then echo "Error! \"Contract ID\" is not a number!"; exit 1; fi
    if [[ $CONTRACT_ID == "0" ]]; then
        exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}')")
        if [[ $exists == "0" ]]; then
            echo "Error! The \"Microcurrency Address\" provided does not exist in the database!"
            exit 1
        fi
    else
        exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}' AND contract_id = $CONTRACT_ID)")
        if [[ $exists == "0" ]]; then
            echo "Error! \"Microcurrency Address\" with provided \"Contract ID\" does not exist in the database!"
            exit 1
        fi
    fi

    # Update the DB
    if [[ $CONTRACT_ID == "0" ]]; then
        sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET active = 0 WHERE micro_address = '${MICRO_ADDRESS,,}'"
    else
        sudo sqlite3 $SQ3DBNAME "UPDATE contracts SET active = 0 WHERE micro_address = '${MICRO_ADDRESS,,}' AND contract_id = $CONTRACT_ID"
    fi

    # Query the DB
    sqlite3 $SQ3DBNAME ".mode columns" "SELECT * FROM contracts WHERE micro_address = '${MICRO_ADDRESS,,}'"


elif [[ $1 = "--add-teller-addr" ]]; then # Add (new) address to teller address book
    EMAIL=$2; MICRO_ADDRESS=$3

    # Input error checking
    exists=$(sqlite3 $SQ3DBNAME "SELECT EXISTS(SELECT * FROM accounts WHERE email = '${EMAIL,,}')")
    if [[ $exists == "0" ]]; then
        echo "Error! There is no account associated with the provided email!"
        exit 1
    fi

    if ! [[ $($BTC validateaddress ${MICRO_ADDRESS,,} | jq '.isvalid') == "true" ]]; then
        echo "Error! Address provided is not correct or Bitcoin Core (microcurrency mode) is down!"
        exit 1
    fi

    # Only one address can be active at a time for each account. Ensure all others are disabled.
    act_id=$(sqlite3 $SQ3DBNAME "SELECT account_id FROM accounts WHERE email = '${EMAIL,,}'")
    sudo sqlite3 $SQ3DBNAME "UPDATE teller_address_book SET active = 0 WHERE account_id = $act_id"

    # Add new address
    sudo sqlite3 $SQ3DBNAME "INSERT INTO teller_address_book (account_id, time, active, micro_address) VALUES ($act_id, $(date +%s), 1, '${MICRO_ADDRESS,,}');"

    # DB Query
    sqlite3 $SQ3DBNAME "SELECT * FROM teller_address_book WHERE account_id = $act_id"

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ Emails ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
elif [[ $1 = "--email-banker-summary" ]]; then # Sends summary of tellers to the administrator and manager
    MESSAGE="Hi Satoshi,<br><br>Here is a summary about each teller.<br><br>"
    MESSAGE="${MESSAGE}<i>Note: Any unsold hash power by your tellers is paid out to their addresses.<br>"
    MESSAGE="${MESSAGE}Also, this unsold hash power does not account for any (underutilized) customer-purchased hash power that has not been assigned to contract.</i><br>"
    MESSAGE="$MESSAGE<br><hr><br><b>Unpaid:</b><br><table border="1"><tr><th>Name</th><th>Mining Power (GH/s)</th><th>Time (Established)</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = teller_sales.account_id) || '</td>',
            '<td>' || (quantity * $HASHESPERCONTRACT / 1000000000)  || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '</tr>'
        FROM teller_sales
        WHERE status IS NULL OR status = 0
EOF
);  MESSAGE="$MESSAGE</table>"

    # Some details about each teller
    MESSAGE="$MESSAGE<br><br><b>Basic Information:</b>"
    MESSAGE="$MESSAGE<table border="1"><tr><th>Name</th><th>TOTAL Mining Power (GH/s)</th><th>SOLD Mining Power (GH/s)</th><th>Total Customers</th><th>Payout Address</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '')) || '</td>',
            '<td>' || COALESCE(((SELECT SUM(quantity) FROM teller_sales WHERE status != 3 AND account_id = accounts.account_id) * $HASHESPERCONTRACT / 1000000000), '')  || '</td>',
            '<td>' || ((SELECT SUM(quantity) FROM contracts WHERE active = 1 AND EXISTS(SELECT * FROM accounts sub WHERE account_id = contracts.account_id AND contact = accounts.account_id)) * $HASHESPERCONTRACT / 1000000000)  || '</td>',
            '<td>' || (SELECT COUNT(*) FROM accounts sub WHERE contact = accounts.account_id) || '</td>',
            '<td>' || COALESCE((SELECT micro_address FROM teller_address_book WHERE active = 1 AND account_id = accounts.account_id), '') || '</td>',
            '</tr>'
        FROM accounts
        WHERE disabled = 0 AND EXISTS(SELECT * FROM accounts sub WHERE contact = accounts.account_id)
EOF
    ); MESSAGE="$MESSAGE</table>"

    /usr/local/sbin/send_email "Satoshi" "${ADMINISTRATOREMAIL}" "Banker Report" "$MESSAGE"
    /usr/local/sbin/send_email "Bitcoin CEO" "${MANAGER_EMAIL}" "Banker Report" "$MESSAGE"

elif [[ $1 = "--email-master-summary" ]]; then # Send sub account summary to a master
    MASTER_EMAIL=$2; EMAIL_ADMIN_IF_SET=$3

    NAME=$(sqlite3 $SQ3DBNAME << EOF
        SELECT
            CASE WHEN preferred_name IS NULL
                THEN first_name
                ELSE preferred_name
            END
        FROM accounts
        WHERE email = '${MASTER_EMAIL,,}'
EOF
    )

    MESSAGE="Hi $NAME,<br><br>Here is an overall detailed summary of your sub account(s)!<br><br><hr>"

    # Accounts/Sales/Contracts
    MESSAGE="$MESSAGE<br><br><table border="1"><tr><th>Name</th><th>Mining Power (GH/s)</th><th>Time (Established)</th><th>Address (Savings Card)</th><th>Total Received</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = contracts.account_id) || '</td>',
            '<td>' || (quantity * $HASHESPERCONTRACT / 1000000000)  || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '<td>' || micro_address || IIF(active = 2, ' (Opened)', '') || '</td>',
            '<td>' || (SELECT CAST(SUM(txs.amount) as REAL) / 100000000 FROM txs WHERE contract_id = contracts.contract_id) || '</td>',
            '</tr>'
        FROM contracts
        WHERE active = 1 AND (SELECT master FROM accounts WHERE account_id = contracts.account_id) = (SELECT account_id FROM accounts WHERE email = '${MASTER_EMAIL,,}')
EOF
);  MESSAGE="$MESSAGE</table>"

    # Send Email
    if [[ -z $EMAIL_ADMIN_IF_SET ]]; then
        /usr/local/sbin/send_email "$NAME" "${MASTER_EMAIL,,}" "Sub Account(s) Summary" "$MESSAGE"
    else
        /usr/local/sbin/send_email "$NAME" "$ADMINISTRATOREMAIL" "Sub Account(s) Summary" "$MESSAGE"
    fi

elif [[ $1 = "--email-teller-summary" ]]; then # Send summary to a Teller (Level 1) Hub/Node
    CONTACT_EMAIL=$2; EMAIL_EXECUTIVE=$3

    NAME=$(sqlite3 $SQ3DBNAME << EOF
        SELECT
            CASE WHEN preferred_name IS NULL
                THEN first_name
                ELSE preferred_name
            END
        FROM accounts
        WHERE email = '${CONTACT_EMAIL,,}'
EOF
    )
    ADDRESS=$(sqlite3 $SQ3DBNAME "SELECT micro_address FROM teller_address_book WHERE active = 1 AND account_id = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')")
    UNPAID=$(sqlite3 $SQ3DBNAME "SELECT (SUM(quantity) * $HASHESPERCONTRACT / 1000000000) FROM teller_sales WHERE (status IS NULL OR status = 0) AND account_id = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')")
    TOTAL=$(sqlite3 $SQ3DBNAME "SELECT (SUM(quantity) * $HASHESPERCONTRACT / 1000000000) FROM teller_sales WHERE status != 3 AND account_id = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')")
    SOLD=$(sqlite3 $SQ3DBNAME "SELECT (SUM(quantity) * $HASHESPERCONTRACT / 1000000000) FROM contracts WHERE active = 1 AND (SELECT contact FROM accounts WHERE account_id = contracts.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')")

    if [ -z $ADDRESS ]; then ADDRESS="You Need To Set One!!!"; fi
    if [ -z $UNPAID ]; then UNPAID=0; fi
    if [ -z $TOTAL ]; then TOTAL=0; SOLD=0; fi
    if [ -z $SOLD ]; then SOLD=0; fi







#BTC=$(cat /etc/bash.bashrc | grep "alias btc=" | cut -d "\"" -f 2)
#SQ3DBNAME=/var/lib/payouts.db

#payouts --teller-email

##################################################################################################!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# Create better (more informative) teller message

#You have 0 GH/s (5 contracts) of remaining (UNSOLD) hash power that is currently directed to for your current and future core customers.

#Hi Jeff,

#	50 coins were mined with mined with your unsold hashrate.....blah blah..az1qjyz6na5v53kud0getxsa5trht6rqrrjtsg59e2

#Stats:
#   Payout Address (for Unsold Contracts): 		az1qjyz6na5v53kud0getxsa5trht6rqrrjtsg59e2
#   Unsold Hashpower:							70 Gh/s (i.e. 7 Contract(s))
#   Sold Hashpower: 							430 GH/s (i.e. 43 contract(s))
#   Total Hashpower: 							500 GH/s (i.e. 50 contract(s))

#Note: Unsold hashpower does not account for any (underutilized) customer-purchased hash power that has not been assigned to contract.














    MESSAGE="Hi $NAME,<br><br>This email contains a summary of all your contracts!<br><br>"
    MESSAGE="${MESSAGE}Your personal bulk contract (teller) payout address: <b><u>$ADDRESS</u></b><br>"
    MESSAGE="${MESSAGE}You currently have <b><u>$UNPAID GH/s of UNPAID</u></b> bulk hash power.<br>"
    MESSAGE="${MESSAGE}There is <b><u>$((TOTAL - SOLD)) GH/s of UNSOLD</u></b> hash power for your current and future core customers.<br><br>"
    MESSAGE="${MESSAGE}<i>Note: Any unsold hash power is paid out to your teller address.<br>"
    MESSAGE="${MESSAGE}Also, unsold hash power does not account for any (underutilized) customer-purchased hash power that has not been assigned to contract.</i><br>"
    MESSAGE="$MESSAGE<br><hr>"

    # Accounts
    MESSAGE="$MESSAGE<br><b>Accounts:</b><br><table border="1"><tr><th>Name</th><th>Master</th><th>Email</th><th>Phone</th><th>Total Received</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') || '</td>',
            '<td>' || COALESCE((SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts _accounts WHERE account_id = accounts.master), '') || '</td>',
            '<td>' || email || '</td>',
            '<td>' || COALESCE(phone, '') || '</td>',
            '<td>' || (SELECT CAST(SUM(amount) AS REAL) / 100000000 FROM txs, contracts WHERE txs.contract_id = contracts.contract_id AND accounts.account_id = contracts.account_id) || '</td>',
            '</tr>'
        FROM accounts
        WHERE contact = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}') AND disabled = 0
EOF
    );  MESSAGE="$MESSAGE</table>"

    # Sales/Contracts
    MESSAGE="$MESSAGE<br><br><b>Sales/Contracts:</b><br><table border="1"><tr><th>Name</th><th>QTY/Total</th><th>Sale ID</th><th>Purchaser</th><th>Time</th><th>Address</th><th>Total Received</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = contracts.account_id) || '</td>',
            '<td>' || quantity || '/' || (SELECT quantity FROM sales WHERE sale_id = contracts.sale_id) || '</td>',
            '<td>' || sale_id || '</td>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = (SELECT account_id FROM sales WHERE sale_id = contracts.sale_id)) || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '<td>' || micro_address || IIF(active = 2, ' (Opened)', '') || '</td>',
            '<td>' || (SELECT CAST(SUM(txs.amount) as REAL) / 100000000 FROM txs WHERE contract_id = contracts.contract_id) || '</td>',
            '</tr>'
        FROM contracts
        WHERE active = 1 AND (SELECT contact FROM accounts WHERE account_id = contracts.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')
EOF
);  MESSAGE="$MESSAGE</table>"

    # Not Delivered
    MESSAGE="$MESSAGE<br><br><b>Not Delivered:</b><br><table border="1"><tr><th>Name</th><th>Email</th><th>Contract ID</th><th>QTY</th><th>Time</th><th>Addresses</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = contracts.account_id) || '</td>',
            '<td>' || (SELECT email FROM accounts WHERE account_id = contracts.account_id) || '</td>',
            '<td>' || contract_id || '</td>',
            '<td>' || quantity || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '<td>' || micro_address || '</td>',
            '</tr>'
        FROM contracts
        WHERE delivered = 0 AND (SELECT contact FROM accounts WHERE account_id = contracts.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')
        GROUP BY micro_address
EOF
    );  MESSAGE="$MESSAGE</table>"

    #Underutilized
    MESSAGE="$MESSAGE<br><br><b>Underutilized:</b><br><table border="1"><tr><th>Purchaser</th><th>Email</th><th>Sale ID</th><th>QTY/Total</th><th>Remaining</th><th>Time</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || (SELECT email FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || sale_id || '</td>',
            '<td>' || (SELECT SUM(quantity) FROM contracts WHERE sale_id = sales.sale_id AND active != 0) || '\' || quantity || '</td>',
            '<td>' || quantity - (SELECT SUM(quantity) FROM contracts WHERE sale_id = sales.sale_id AND active != 0) || '</td>',
            '<td>' || DATETIME(sales.time, 'unixepoch', 'localtime') || '</td>',
            '</tr>'
        FROM sales
        WHERE status != 3 AND (SELECT contact FROM accounts WHERE account_id = sales.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')
            AND (quantity - (SELECT SUM(quantity) FROM contracts WHERE sale_id = sales.sale_id AND active != 0)) > 0
EOF
    );  MESSAGE="$MESSAGE</table>"

    # Not Paid
    MESSAGE="$MESSAGE<br><br><b>Not Paid:</b><br><table border="1"><tr><th>Name</th><th>Email</th><th>Sale ID</th><th>Total</th><th>Time</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || (SELECT email FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || sale_id || '</td>',
            '<td>' || quantity || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '</tr>'
        FROM sales
        WHERE status = 0 AND (SELECT contact FROM accounts WHERE account_id = sales.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')
EOF
    );  MESSAGE="$MESSAGE</table>"

    # Trials
    MESSAGE="$MESSAGE<br><br><b>Trials:</b><br><table border="1"><tr><th>Name</th><th>Email</th><th>Sale ID</th><th>Total</th><th>Time</th><th>Days Active</th></tr>"
    MESSAGE="$MESSAGE"$(sqlite3 $SQ3DBNAME << EOF
.separator ''
        SELECT
            '<tr>',
            '<td>' || (SELECT first_name || COALESCE(' (' || preferred_name || ') ', ' ') || COALESCE(last_name, '') FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || (SELECT email FROM accounts WHERE account_id = sales.account_id) || '</td>',
            '<td>' || sale_id || '</td>',
            '<td>' || quantity || '</td>',
            '<td>' || DATETIME(time, 'unixepoch', 'localtime') || '</td>',
            '<td>' || ((STRFTIME('%s') - time) / 86400) || '</td>',
            '</tr>'
        FROM sales
        WHERE status = 2 AND (SELECT contact FROM accounts WHERE account_id = sales.account_id) = (SELECT account_id FROM accounts WHERE email = '${CONTACT_EMAIL,,}')
EOF
    );  MESSAGE="$MESSAGE</table>"

    # Send Email
    if [[ -z $EMAIL_EXECUTIVE ]]; then
        /usr/local/sbin/send_email "$NAME" "${CONTACT_EMAIL,,}" "Teller (Lvl 1) Contract Summary" "$MESSAGE"
    else
        if [[ "$EMAIL_EXECUTIVE" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,4}$ ]]; then # See if there is a valid email passed
            /usr/local/sbin/send_email "$NAME" "$EMAIL_EXECUTIVE" "Teller (Lvl 1) Contract Summary" "$MESSAGE" # Send email to passed email
        else
            /usr/local/sbin/send_email "$NAME" "$ADMINISTRATOREMAIL" "Teller (Lvl 1) Contract Summary" "$MESSAGE" # Otherwise, send email to administrator
        fi
    fi

elif [[ $1 = "--email-core-customer" ]]; then # Send a payout email to a core customer
    NAME=$2; EMAIL=$3; AMOUNT=$4; TOTAL=$5; HASHRATE=$6; CONTACTPHONE=$7; CONTACTEMAIL=$8; COINVALUESATS=$9; USDVALUESATS=${10}; LATEST_EPOCH_PERIOD=${11}; ADDRESSES=${12}; TXIDS=${13}; EMAIL_ADMIN_IF_SET=${14}

    # Input checking
    if [[ -z $NAME || -z $EMAIL || -z $AMOUNT || -z $TOTAL || -z $HASHRATE || -z $CONTACTPHONE || -z $CONTACTEMAIL || -z $COINVALUESATS || -z $USDVALUESATS || -z $ADDRESSES || -z $TXIDS ]]; then
        echo "Error! Insufficient Parameters!"
        exit 1
    elif [[ ! $(echo "${ADDRESSES}" | awk '{print toupper($0)}') == *"${NETWORKPREFIX}1Q"* ]]; then
        echo "Error! Incorrect Address Type!"
        exit 1
    fi

    # Find out if the user has unpaid or trial mode sales
    STATUS=$(sqlite3 $SQ3DBNAME "SELECT status FROM sales WHERE (SELECT account_id FROM accounts WHERE email = '$EMAIL') = account_id AND (status = 0 OR status = 2) ORDER BY status ASC LIMIT 1")
    if [[ -z $STATUS ]]; then
        STATUS=""
    elif [[ $STATUS -eq 0 ]]; then
        STATUS="<br>Also, just a quick reminder to get the money (cash) sent to cover the unpaid mining contract(s)... Thank You!<br>"
    elif [[ $STATUS -eq 2 ]]; then
        STATUS="<br>Also, a quick reminder that this mining contract is in trial mode. Reach out today and let's make it official! Thank You!<br>"
    fi

    # There may be an added suffix to the address to indicate its status
    ADDRESSES=${ADDRESSES//./<br>}
    ADDRESSES=${ADDRESSES//_0/ -- Deprecated}
    ADDRESSES=${ADDRESSES//_1/} # Active
    ADDRESSES=${ADDRESSES//_2/ -- Opened} # Active, but opened

    TXIDS=${TXIDS//./<\/li><li>}

    MESSAGE=$(cat << EOF
        <html><head></head><body>
            Hi ${NAME},<br><br>

            You have successfully mined <b><u>$AMOUNT</u></b> coins on the \"${NETWORK}\" network ${CLARIFY}with a hashrate of <b>${HASHRATE} GH/s</b> to the following address(es):<br><br>
            <b>${ADDRESSES}</b><br><br>
            So far, you have mined a total of <b><u>${TOTAL}</u></b> coins<sup>${NETWORKPREFIX}</sup> worth <b>$(awk -v total=${TOTAL} -v coinvaluesats=${COINVALUESATS} 'BEGIN {printf "%'"'"'.2f\n", total * coinvaluesats}') \$ATS </b><sup>(\$$(awk -v total=${TOTAL} -v coinvaluesats=${COINVALUESATS} -v usdvaluesats=${USDVALUESATS} 'BEGIN {printf "%'"'"'.2f\n", total * coinvaluesats / usdvaluesats}') USD)</sup> as of this email!<br><br>
            Notice! Always ensure the key(s) associated with this/these address(es) are in your possession!!
            Please reach out ASAP if you need a new savings card!<br><br>
            Please utilize our ${NETWORK} block explorer to get more details on an address or TXID: $EXPLORER<br>
            ${STATUS}
            <br><hr><br>

            <b><u>Market Data</u></b> (as of this email)
            <table>
                <tr>
                    <td></td>
                    <td>\$1.00 USD</td>
                    <td></td><td></td><td></td><td></td><td></td>
                    <td>$(awk -v usdvaluesats=${USDVALUESATS} 'BEGIN {printf "%'"'"'.2f\n", usdvaluesats}') \$ATS</td>
                    <td></td><td></td><td></td><td></td><td></td>
                    <td>($(awk -v usdvaluesats=${USDVALUESATS} 'BEGIN {printf "%'"'"'.8f\n", usdvaluesats / 100000000}') bitcoins)</td>
                </tr><tr>
                    <td></td>
                    <td>1 ${NETWORKPREFIX} coin</sup></td>
                    <td></td><td></td><td></td><td></td><td></td>
                    <td>$(awk -v coinvaluesats=${COINVALUESATS} 'BEGIN {printf "%'"'"'.2f\n", coinvaluesats}') \$ATS</td>
                    <td></td><td></td><td></td><td></td><td></td>
                    <td>($(awk -v coinvaluesats=${COINVALUESATS} 'BEGIN {printf "%'"'"'.8f\n", coinvaluesats / 100000000}') bitcoins)</td>
                </tr>
            </table><br>

            <b><u>Key Terms</u></b>
            <table>
                <tr>
                    <td></td>
                    <td>\$ATS</td>
                    <td></td><td></td><td></td><td></td><td></td><td></td><td></td>
                    <td>Short for satoshis. The smallest unit in a bitcoin. There are 100,000,000 satoshis in 1 bitcoin.</td>
                </tr><tr>
                    <td></td>
                    <td>${DENOMINATION}</td>
                    <td></td><td></td><td></td><td></td><td></td><td></td><td></td>
                    <td>Short for ${DENOMINATIONNAME}. The smallest unit in an ${NETWORKPREFIX} coin. There are 100,000,000 ${DENOMINATIONNAME} in 1 ${NETWORKPREFIX} coin.</td>
                </tr>
            </table><br>

            <b><u>Contact Details</u></b><br>
            <ul>
                <li>${CONTACTPHONE}</li>
                <li>${CONTACTEMAIL}</li>
            </ul><br>

            <b><u>TXID(s):</u></b><br>
            <ul>
                <li>${TXIDS}</li>
            </ul><br>

            <b><u>We\`re Here to Help!</u></b><br>
            <ul>
                <li>Don't hesitate to reach out to purchase more mining power!!!</li>
                <li>If you’re interested in mining for yourself, ask us about the ${NETWORKPREFIX} / BTC Quarter Stick miner.</li>
                <li>To join the \"${NETWORKPREFIX} Money\" community and the discussion check out the forum @ <a href=\"https://forum.satoshiware.org\"><u><i>forum.satoshiware.org</i></u></a></li>
            </ul><br>
        </body></html>
EOF
    )

    # Send Email
    if [[ -z $EMAIL_ADMIN_IF_SET ]]; then
        /usr/local/sbin/send_email "$NAME" "$EMAIL" "You mined $AMOUNT coins!" "$MESSAGE"
    else
        /usr/local/sbin/send_email "$NAME" "$ADMINISTRATOREMAIL" "You mined $AMOUNT coins! (Payout $LATEST_EPOCH_PERIOD/$MAX_EPOCH_PERIOD)" "$MESSAGE"
    fi

else
    echo "Method not found"
    echo "Run script with \"--help\" flag"
    echo "Script Version 0.29"
fi

##################################################################################################
# Update Teller email - already some new code going on.
# Make a backup - rsync onto node level 3's.
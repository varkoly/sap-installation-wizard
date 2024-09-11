#!/bin/bash -x

# sap_inst.sh - is a script used to install SAP products
#
# Copyright (c) 2013 SAP AG
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation only version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>.

usage () {
	cat <<-EOF

		#######################################################################
		# $(basename $0) -i -m [ -d -t ]
		#
		#  i ) SAPINST_PRODUCT_ID - SAPINST Product ID
		#  m ) SAPCD_INSTMASTER - Path to the SAP Installation Master Medium
		#  d ) SAPINST_DIR - The directory where the installation will be prepared
		#  t ) DBTYPE - Database type, e.g. ADA, DB6, ORA or SYB
		#
		#######################################################################
EOF
	echo
}

SAPCD_INSTMASTER=""
SAPINST_PRODUCT_ID=""
SAPINSTNR=""
SAPINST_DIR=""

# Optionally overrule parameters from answer files by command line arguments
while getopts "m:i:y:d:s:n:p:t:h\?" options; do
	case $options in
		m ) SAPCD_INSTMASTER=${OPTARG};; # Path to the SAP Installation Master Medium (has to be full-qualified)
		i ) SAPINST_PRODUCT_ID=$OPTARG;;  # SAPINST Product ID
		y ) continue;; # We ignore product type
		d ) SAPINST_DIR=${OPTARG};; # The directory where the installation will be prepared
                s ) SID=$OPTARG;;  # SAP System ID
                n ) SAPINSTNR=$OPTARG;;  # SAP Instance Number
                p ) MASTERPASS=$OPTARG;;  # Masterpassword
		t ) DBTYPE=${OPTARG};; # Database type, e.g. ADA, DB6, ORA, SYB or HDB
		h | \? ) usage
		        exit $ERR_invalid_args;;
		* ) usage
		        exit $ERR_invalid_args;;
	esac
done

###########################################
# globals
###########################################
# TMPDIR="/tmp"
TMPDIR=$(mktemp -t -d sap_install_XXXXX)
chmod 755 $TMPDIR

if [ -z "$SAPINST_DIR" ]; then
   SAPINST_DIR=$( dirname $SAPCD_INSTMASTER)
fi

# <n>th installation on this host. Specified by installation sub-directory. For multiple installations on a single host
INSTALL_COUNT=$( echo ${SAPINST_DIR} | awk -F '/' '{print $NF}' )

# Which Database is going to be used? Can be empty.
if [ -r ${SAPINST_DIR}/product.data ]; then
	# ggf. DBTYPE von Kommandozeile ueberschreiben lassen
	DBTYPE=${DBTYPE:=$($(grep DATABASE ${SAPINST_DIR}/product.data| cut -d'"' -f4))}
fi

[ "${#DBTYPE}" -ne 3 ] && [ -n "${DBTYPE}" ] && usage && echo "Please enter a valid database type, e.g. ADA, DB6, ORA or SYB." && exit $ERR_missing_entries
DBTYPE=$(echo $DBTYPE | tr [:lower:] [:upper:])


# YaST Uebergabeparameterdateien
A_VIRTHOSTNAME="${SAPINST_DIR}/ay_q_virt_hostname"
A_VIRT_IP_ADDR="${SAPINST_DIR}/ay_q_virt_ip_addr"
A_VIRT_IP_NETMASK="${SAPINST_DIR}/ay_q_virt_ip_netmask"
A_TSHIRT="${SAPINST_DIR}/ay_q_tshirt"

A_FILES="${A_VIRTHOSTNAME} ${A_VIRT_IP_ADDR} ${A_VIRT_IP_NETMASK} ${A_TSHIRT}"

###########################################
# Initialisierung
###########################################
REAL_HOSTNAME=$(hostname)
[ -f ${A_IP_ADDR} ] && IP_ADDR=$(< ${A_IP_ADDR})

###########################################
# Network Configuration
###########################################
virt_interface_name=""		# alias_name (eth0:$virt_interface_name)
virt_ip_pool="192.168.155.1 192.168.155.2 172.16.168.1 10.168.155.1"
[ -f ${A_VIRT_IP_ADDR} ] && virt_ip_pool=$(< ${A_VIRT_IP_ADDR})

virt_ip_address=""              # ip_address from $virt_ip_pool

virt_ip_netmask="255.255.255.0"
[ -f ${A_VIRT_IP_NETMASK} ] && virt_ip_netmask=$(< ${A_VIRT_IP_NETMASK})

interface_name=""		# eth0
interface_macaddr=""		# MAC address of eth0


###########################################
# Define ERRORS section
###########################################
ERR_invalid_args=1
ERR_no_suid=2
ERR_no_tars_found=3
ERR_unknown_vendor=4
ERR_no_ip_free=5
ERR_no_java_found=6
ERR_no_unrar_found=7
ERR_sap_no_eula=8
ERR_sap_eula_refused=9
ERR_create_xuser_failed=10
ERR_rpm_install=11
ERR_internal=12
ERR_missing_entries=13
ERR_nomasterPwd=14
ERR_last=15

err_message[0]="Ok"
err_message[1]="Invalid Arguments."
err_message[2]="You should be root to start this program."
err_message[3]="No SAP archives found."
err_message[4]="This installation supports only ${supported_string}"
err_message[5]="No free IP Address found using the following list : ${virt_ip_pool}"
err_message[6]="No Java Runtime found."
err_message[7]="No unrar found."
err_message[8]="No SAPEULA License found."
err_message[9]="License terms refused."
err_message[10]="Creation of .XUSER.62 failed."
err_message[11]="RPM Error."
err_message[12]="Internal error! Call stack: ${FUNC_NAME[@]}"
err_message[13]="Mandatory User input missing!"
err_message[14]="No Masterpassword provided"
err_message[15]=""

###########################################
# Functions:
###########################################

do_exit() {
        exit_code=$1
        if [ ${exit_code} -le ${ERR_last} ]; then
                echo -e "${err_message[${exit_code}]}"
                yast_popup_wait "${err_message[${exit_code}]}"
        fi
        exit ${exit_code}
}

search_free_virt_ip_address () {
	# search for a free IP address in $virt_ip_pool to use with a virtual interface:
        for i in ${virt_ip_pool}; do
                l=$(netstat -ei | grep "${i}")
                if [ -z "${l}" ]; then
                        virt_ip_address=${i}
                        break
                fi
        done
        if [ -z "${virt_ip_address}" ]; then
                do_exit ${ERR_no_ip_free}
        fi
}

search_free_alias() {
	# search for free alias device name for the virtual interface (ex. eth0:1)
	# search_free_alias ${interface_name}
        local NN=$1
        for i in $(seq 0 10)
        do
                alias="${NN}:${i}"
                l=$(netstat -ei | grep "^${alias}")
                if [ -z "${l}" ]; then
                        virt_interface_name=${i}
                        break
                fi
        done
}

activate_network_alias() {
	# Activate the virtual interface by reboot
	# and call ip to activate it immediately

        local pairs directory filename _res text

	if [ -e /etc/redhat-release ]; then
		# Red Hat
		directory=/etc/sysconfig/network-scripts
		pairs="DEVICE=${interface_name}:IPADDR=${virt_ip_address} NETMASK=${virt_ip_netmask} ONBOOT=yes NAME=${virt_interface_name}"
	else
		# SuSE
	        directory=/etc/sysconfig/network
		# adding a virtual interface to the one we have
		# its easy: only add the 4 new lines to the config-file
		pairs="IPADDR_$virt_interface_name=${virt_ip_address} NETMASK_$virt_interface_name=${virt_ip_netmask} LABEL_$virt_interface_name=$virt_interface_name PREFIXLEN_$virt_interface_name=''"
	fi

        # filename looks like: ifcfg-eth-id-00:11:25:12:35:bd
        # filename=$(ls ${directory}|grep ${interface_macaddr})
	# Since SLE-11 we only setup ifcfg-eth0
	filename='ifcfg-eth0'

        for i in ${pairs}; do
                echo -e "${i}" >> ${directory}/${filename}
        done
        echo "  added settings to ${directory}/${filename}"

        # START THE INTERFACE now
	_res=$( ip address add ${virt_ip_address}/${virt_ip_netmask} dev ${interface_name} label ${interface_name}:${virt_interface_name} )

        text=$(grep "${virt_hostname}" /etc/hosts | head -n 1)
        if [ -n "${text}" ]; then
                $(echo -e "${text}" | grep ${virt_ip_address})
                if [ $? -ne 0 ]; then
                        echo -e "Hostname ${virt_hostname} used with a different address as ${virt_ip_address}."
                        echo -e "Please change it and restart the installation."
                fi
        else
                echo -e "${virt_ip_address}\t${virt_hostname}.$(dnsdomainname)\t${virt_hostname}" >> /etc/hosts
        fi
}

virt_interface_exists() {
        # check if the virtual interface exists
        # takes: the virt_hostname as parameter
        # returns: 0 if it is already there, 1 if not
        # side effects: sets $interface_macaddr
        [ -z "$1" ] && do_exit $ERR_internal # we need that parameter!

        local fakehost iface
        fakehost=$(grep -m1 -E "^[^#].*$1" /etc/hosts)
        if [ ${#fakehost[*]} -ge 2 ]; then
                iface=$(ip addr show | grep ${fakehost})
                if [ ${#iface[*]} -eq 7 ]; then
                        echo -e "Device ${iface[6]} used for hostname ${virt_hostname}"
                        iface=$(ip addr show dev ${iface[6]} | grep ether)
                        interface_macaddr=${iface[1]} # this is for activate_network_alias
                        return 0
                fi
        else
                return 1
        fi
}

create_virt_interface () {
	# create a virtual network interface for hostname $virt_hostname:
        local _val
        if virt_interface_exists "${virt_hostname}"; then
                echo -e "Hostname ${virt_hostname} already configured."
        else
                # read only 1st line
                _val=$(LANG=C netstat -ei | grep -vi 'kernel' | grep -vi '^iface' | grep -vi '^lo' | head -n 1)

                interface_name=$(echo ${_val} | awk '{ print $1}')
                interface_macaddr=$(echo ${_val} | awk '{ print $5}'|tr [:upper:] [:lower:])

                search_free_alias ${interface_name}
                search_free_virt_ip_address

                echo "Found interface: ${interface_name} . Alias is ${virt_interface_name}"
                activate_network_alias
        fi
}

create_sapstartsrv_resources () {
        if [ ! -f /etc/pam.d/sapstartsrv ]; then
                # create /etc/pam.d/sapstartsrv
        	cat > /etc/pam.d/sapstartsrv <<-EOF
	#%PAM-1.0
	auth    requisite       pam_unix_auth.so nullok
EOF
        fi

        ## ensure default md5-encryption (should already be set by AutoYaST)
        #sed -i "s@^CRYPT_FILES=blowfish@CRYPT_FILES=md5@" /etc/default/passwd
}

adapt_maxdb_settings() {

        local XSERVER_STATE DBSTATE DBCACHE MAXCPU

        # d031117 - Database has to be at least in ADMIN mode

        XSERVER_STATE=$(pgrep vserver)
        if [ -z "${XSERVER_STATE}" ]; then
                # vserver (executable x_server) was not running
                su -c "x_server start" -l ${sid}adm
        fi

        DBSTATE=$(su -c "dbmcli -U c db_state" -l ${sid}adm | grep -A 1 State | tail -n 1)
        if [ "${DBSTATE}" = "OFFLINE" ]; then
                # MaxDB not in ADMIN mode
                su -c "dbmcli -U c db_cold" -l ${sid}adm
        fi

        #
        # TShirt sizing
        #
        case $TSHIRT in
                XS )
                    DBCACHE=512 # DBCACHE = 512 MB
                    MAXCPU=1 # use 1 CPU
                    ;;
                S )
                    DBCACHE=1024 # DBCACHE = 1024 MB
                    MAXCPU=1 # use 1 CPU
                    ;;
                M )
                    DBCACHE=1536 # DBCACHE = 1536 MB
                    MAXCPU=1 # use 1 CPU
                    ;;
                L )
                    DBCACHE=2048 # DBCACHE = 2048 MB
                    MAXCPU=2 # use 2 CPUs
                    ;;
                * )
                    DBCACHE=1024 # DBCACHE = 1024 MB
                    MAXCPU=1 # use 1 CPU
                    ;;
        esac
        # MaxDB Data Cache: CACHE_SIZE in 8KB pages
        su -c "dbmcli -U c param_directput CACHE_SIZE $(( ${DBCACHE} * 128 ))" -l ${sid}adm >/dev/null 2>&1
        su -c "dbmcli -U c param_directput MAXCPU ${MAXCPU}" -l ${sid}adm >/dev/null 2>&1


        if [ "${DBSTATE}" = "OFFLINE" ]; then
                # MaxDB was OFFLINE, so we stop it again
                su -c "dbmcli -U c db_offline" -l ${sid}adm
        fi

        if [ -z "${XSERVER_STATE}" ]; then
                # vserver (executable x_server) was not running
                # so we stop it again
                su -c "x_server stop" -l ${sid}adm
        fi
}

adapt_db6_settings() {
        # start db2
        su -c "db2start"  -l db2${sid}

        #
        # TShirt sizing
        #
        # Adapt configuration for DB6 V9
        # - dbm cfg  INSTANCE_MEMORY AUTOMATIC
        # - db  cfg  DATABASE_MEMORY <value>
        # - STSM is on
        case $TSHIRT in
                XS )
                    # X GB RAM
                    # =>  1 GB = 1.000.000 KB = 4KB * 250.000
                          su -c "db2 update db cfg for ${sid} using DATABASE_MEMORY 250000"  -l db2${sid}
                    ;;
                S )
                    # 12 GB RAM for 3 SAP systems
                    # => 40% for DB2 = 4.8 GB / 3 = 1.6 GB = 1.600.000 KB = 4KB * 400.000
                          su -c "db2 update db cfg for ${sid} using DATABASE_MEMORY 400000"  -l db2${sid}
                    ;;
                M )
                    # 12 GB RAM for 1 SAP system
                    # 12 GB RAM for 2 SAP systems
                    # 24 GB => 40% = 9.6 / 3 = 3.2 GB = 3.200.000 KB = 4KB * 800.000
                          su -c "db2 update db cfg for ${sid} using DATABASE_MEMORY 800000"  -l db2${sid}
                    ;;
                L )
                    # 16 GB RAM for 1 SAP system
                    # 12 GB RAM for 2 SAP systems
                    # 28 GB => 40% = 11.2 GB / 3 = 3.7 GB = 3.700.000 KB = 4KB * 925.000
                          su -c "db2 update db cfg for ${sid} using DATABASE_MEMORY 925000"  -l db2${sid}
                    ;;
                * )
                    # Use the same configuration as for M
                          su -c "db2 update db cfg for ${sid} using DATABASE_MEMORY 800000"  -l db2${sid}
                    ;;
        esac


        #
        # General db2 configuration
        #
        su -c "db2 ALTER BUFFERPOOL IBMDEFAULTBP size 10000 AUTOMATIC"  -l db2${sid}

}

adapt_sybase_settings() {

        local ASE_STATE
        local config_ase_1="${TMPDIR}/config_ase_1.sql"
        local config_ase_1_log="${TMPDIR}/config_ase_1.log"
        local config_ase_2="${TMPDIR}/config_ase_2.sql"
        local config_ase_2_log="${TMPDIR}/config_ase_2.log"

        #
        # start ASE if not running
        #
        ASE_STATE=$(su -c '$SYBASE/$SYBASE_ASE/install/showserver' -l syb${sid} | grep -c ".*/sybase/${DBSID}.*dataserver.*")
        if [ "${ASE_STATE}" = "0" ]; then
          echo "Starting ASE as it is currently down..."
          su -c '$SYBASE/$SYBASE_ASE/install/startserver -f $SYBASE/$SYBASE_ASE/install/RUN_'${DBSID}' > /dev/null' -l syb${sid}
          # give it some time to finish recovery
          sleep 30
        fi

        #
        # Configuration is adjusted by first generating SQL scripts, then finally running it.
        # There are two scripts being generated and executed in total. The first one to reset all memory consumers to a low value.
        # The second to set a new 'max memory' value and to distribute the new total memory across certain consumers.
        #
        echo "Writing ASE configuration script to ${config_ase_1} and ${config_ase_2}..."
        #touch ${config_ase_1} && chown syb${sid} ${config_ase_1}
        touch ${config_ase_1} && chown syb${sid} ${config_ase_1} && chmod a+x ${TMPDIR}
        touch ${config_ase_1_log} && chown syb${sid} ${config_ase_1_log}
        su -c "echo \"use master\ngo\" >> ${config_ase_1}" -l syb${sid}
        # reset all memory consumers to minimal size, this ensures we can set 'max memory' to a new and maybe lower value later on
        su -c "echo \"alter thread pool syb_default_pool with thread count = 2\ngo\" >> ${config_ase_1}" -l syb${sid}
        su -c "echo \"exec sp_configure 'procedure cache size', 0, '20M'\ngo\" >> ${config_ase_1}" -l syb${sid}
        su -c "echo \"exec sp_configure 'statement cache size', 0, '5M'\ngo\" >> ${config_ase_1}" -l syb${sid}

        if [ $TSHIRT = "S" ]; then
          su -c "echo \"exec sp_configure 'number of user connections', 100\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'number of locks', 750000\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'max online engines', 4\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'kernel resource memory', 8192\ngo\" >> ${config_ase_1}" -l syb${sid}
        fi

        if [ $TSHIRT = "XS" ]; then
          su -c "echo \"exec sp_configure 'number of user connections', 100\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'number of locks', 750000\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'number of open objects', 40000\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'number of open indexes', 40000\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'number of open partitions', 30000\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'max online engines', 2\ngo\" >> ${config_ase_1}" -l syb${sid}
          su -c "echo \"exec sp_configure 'kernel resource memory', 8192\ngo\" >> ${config_ase_1}" -l syb${sid}
        fi

        su -c "echo \"exec sp_poolconfig 'default data cache', '0K', '128K'\ngo\" >> ${config_ase_1}" -l syb${sid}
        su -c "echo \"exec sp_cacheconfig 'default data cache', '50M'\ngo\" >> ${config_ase_1}" -l syb${sid}
        su -c "echo \"shutdown with wait='00:01:00'\ngo\" >> ${config_ase_1}" -l syb${sid}

        touch ${config_ase_2} && chown syb${sid}:sapsys ${config_ase_2}
        touch ${config_ase_2_log} && chown syb${sid} ${config_ase_2_log}
        su -c "echo \"use master\ngo\" >> ${config_ase_2}" -l syb${sid}

        #
        # T-Shirt sizing of ASE server configuration
        #
        case $TSHIRT in
                XS )
                    # 1GB memory, 1 thread
                    su -c "echo \"alter thread pool syb_default_pool with thread count = 1\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'max memory', 0, '1024M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'procedure cache size', 0, '242M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'statement cache size', 0, '30M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_cacheconfig 'default data cache', '100M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'compression info pool size', 16384\ngo\" >> ${config_ase_2}" -l syb${sid}
                    ;;
                S )
                    # 1.5GB memory, 2 threads
                    su -c "echo \"alter thread pool syb_default_pool with thread count = 2\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'max memory', 0, '1602M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'procedure cache size', 0, '384M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'statement cache size', 0, '50M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_cacheconfig 'default data cache', '300M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'compression info pool size', 32768\ngo\" >> ${config_ase_2}" -l syb${sid}
                    ;;
                L )
                    # 4GB memory, 8 threads
                    su -c "echo \"alter thread pool syb_default_pool with thread count = 8\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'max memory', 0, '4096M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'procedure cache size', 0, '512M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'statement cache size', 0, '100M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    # 2450MB Data Cache with 2 Pools (2048MB 16K, 402MB 128K)
                    su -c "echo \"exec sp_cacheconfig 'default data cache', '2460M', 'cache_partition=2'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_poolconfig 'default data cache', '384M', '128K'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'compression info pool size', 32768\ngo\" >> ${config_ase_2}" -l syb${sid}
                    ;;
                * )
                    # includes M
                    # 2.5GB memory, 4 threads
                    su -c "echo \"alter thread pool syb_default_pool with thread count = 4\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'max memory', 0, '2630M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'procedure cache size', 0, '512M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'statement cache size', 0, '100M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    # 1024MB Data Cache with 2 Pools (896MB 16K, 128MB 128K)
                    su -c "echo \"exec sp_cacheconfig 'default data cache', '1024M'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_poolconfig 'default data cache', '128M', '128K'\ngo\" >> ${config_ase_2}" -l syb${sid}
                    su -c "echo \"exec sp_configure 'compression info pool size', 32768\ngo\" >> ${config_ase_2}" -l syb${sid}
                    ;;
        esac
        # machine size-independent configuration
        su -c "echo \"exec sp_configure 'number of aux scan descriptors', 2048\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'maximum job output', 2147483647\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'row lock promotion HWM', 2147483647\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'row lock promotion LWM', 2147483647\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'cpu grace time', 1000\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'additional network memory', 10485760\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_configure 'kernel resource memory', 16384\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_altermessage 1105, 'with_log', 'true'\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_altermessage 2901, 'with_log', 'true'\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_altermessage 701, 'with_log', 'true'\ngo\" >> ${config_ase_2}" -l syb${sid}
        su -c "echo \"exec sp_altermessage 12205, 'with_log', 'true'\ngo\" >> ${config_ase_2}" -l syb${sid}

#TODO WE HAVE TO DECIDE IT WHAT TO DO??
        # execute generated SQL scripts
        echo "Now execute ${config_ase_1} ..."
        su -c "isql -S${DBSID} -Usapsa -P${MASTERPASS} -w999 -i${config_ase_1} -o${config_ase_1_log} --conceal" -l syb${sid}

        echo "Restarting ASE ..."
        su -c '$SYBASE/$SYBASE_ASE/install/startserver -f $SYBASE/$SYBASE_ASE/install/RUN_'${DBSID}' > /dev/null' -l syb${sid}

        # give it some time to finish
        sleep 30

        echo "Now execute ${config_ase_2} ..."
        su -c "isql -S${DBSID} -Usapsa -P${MASTERPASS} -w999 -i${config_ase_2} -o${config_ase_2_log} --conceal" -l syb${sid}

        # finally, remove generated SQL scripts
        rm -f ${config_ase_1}
        rm -f ${config_ase_2}

}

adapt_sap_instance_profile () {
# Adapt Instance Profile with (dynamic) reasonable configuration settings
        local main_memory_KB main_memory_MB buffer_memory_MB initial_size_MB instance_profile_path oldstring

	# allow also dialog instance "D* instead of DVEBMGS*"
        instance_profile_path=$(ls -1 /usr/sap/${SID}/SYS/profile/${SID}_D*${SAPINSTNR}_${virt_hostname} 2>/dev/null)
#        # rename instance profile

        # adapt ABAP profile if available
        if [ -f ${instance_profile_path} ]; then

                if [ $(uname -m) != "i686" ]; then
                        # 64-bit settings
                        # delete PHYS_MEMSIZE and enable STD memory management
                        sed -i "/^PHYS_MEMSIZE/d" ${instance_profile_path}
                        echo "es/implementation = std" >> ${instance_profile_path}

                        # increase buffers
                        case $TSHIRT in
                                XS )
                                    echo "abap/buffersize = 200000" >> ${instance_profile_path} # 200 MB ABAP Buffer
                                    echo "zcsa/table_buffer_area = 30000000" >> ${instance_profile_path} # 30 MB Table Buffer
                                    # reduce number of workprocesses
                                    oldstring=$(grep -m1 -E '^rdisp/wp_no_dia' ${instance_profile_path}) || oldstring=""
                                    sed -i "s@${oldstring}@rdisp/wp_no_dia = 3@" ${instance_profile_path}
                                    oldstring=$(grep -m1 -E '^rdisp/wp_no_btc' ${instance_profile_path}) || oldstring=""
                                    sed -i "s@${oldstring}@rdisp/wp_no_btc = 2@" ${instance_profile_path}
                                    ;;
                                S )
                                    echo "abap/buffersize = 300000" >> ${instance_profile_path} # 300 MB ABAP Buffer
                                    echo "zcsa/table_buffer_area = 30000000" >> ${instance_profile_path} # 30 MB Table Buffer
                                    ;;
                                M )
                                    echo "abap/buffersize = 500000" >> ${instance_profile_path} # 500 MB ABAP Buffer
                                    echo "zcsa/table_buffer_area = 30000000" >> ${instance_profile_path} # 30 MB Table Buffer
                                    ;;
                                L )
                                    echo "abap/buffersize = 1000000" >> ${instance_profile_path} # 1000 MB ABAP Buffer
                                    echo "zcsa/table_buffer_area = 200000000" >> ${instance_profile_path} # 200 MB Table Buffer
                                    ;;
                                * )
                                    echo "abap/buffersize = 500000" >> ${instance_profile_path} # 500 MB ABAP Buffer
                                    echo "zcsa/table_buffer_area = 30000000" >> ${instance_profile_path} # 30 MB Table Buffer
                                    ;;
                        esac

                        # configure Instance size
                        # calculate available memory
                        main_memory_KB=$(awk -F" " '{if (match ($1,"^MemTotal")) print $2}' /proc/meminfo)
                        main_memory_MB=$(( ${main_memory_KB} / 1024 ))
                        # example line: "Shared memory....................: 1247.6 MB"
                        buffer_memory_MB=$(su -c "sappfpar check pf=${instance_profile_path}" -l ${sid}adm | awk -F " " '{if (match ($1,"^Shared") && match ($4,"MB$")) print $3}' | awk -F "." '{print $1}')
                        initial_size_MB=$(( ${main_memory_MB} - ${buffer_memory_MB} - 2048 ))
                        # rounding to full 1024 MegaBytes
                        initial_size_MB=$(( ( $initial_size_MB + 1024 ) / 1024 * 1024 ))
                        # minimum of 1024 MB Extended Memory
                        [ 1024 -gt $initial_size_MB ] && initial_size_MB=1024
                        echo "em/initial_size_MB = ${initial_size_MB}" >> ${instance_profile_path}

                        # Configure HTTP
                        sed -i 's@icm/server_port_0 = PROT=HTTP,PORT=80\$\$@icm/server_port_0 = PROT=HTTP,PORT=80\$\$,PROCTIMEOUT=600,TIMEOUT=600@' ${instance_profile_path}

                cat >> ${instance_profile_path} <<-EOF
			icm/server_port_1 = PROT=HTTPS,PORT=443\$\$,PROCTIMEOUT=600,TIMEOUT=600
			icm/server_port_2 = PROT=SMTP,PORT=25\$\$,PROCTIMEOUT=600,TIMEOUT=600
			icm/host_name_full = ${virt_hostname}.$(dnsdomainname)
			# needed for SAP NW Business Client
			ssf/name = SAPSECULIB
			#sec/libsapsecu = /sapmnt/${SID}/exe/libsapcrypto.so
			#ssf/ssfapi_lib = /sapmnt/${SID}/exe/libsapcrypto.so
			#ssl/ssl_lib = /sapmnt/${SID}/exe/libsapcrypto.so

			#login/accept_sso2_ticket = 1
			#login/create_sso2_ticket = 2

			sapgui/user_scripting = true
			#login/no_automatic_user_sapstar = 0
			zcsa/installed_languages = 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdi
EOF

                else
                        # 32-bit settings
                        # change PHYS_MEMSIZE to a reasonable value - deletion activates 100% Kernel default...
                        sed -i "/^PHYS_MEMSIZE/d" ${instance_profile_path}
                fi

		# remove temporary profiles of sapinst, e.g. NPL_DVEBMGS42_nplhost.1 and DEFAULT.1.PFL
		rm -f ${instance_profile_path}\.?
		rm -f $(dirname ${instance_profile_path})/DEFAULT\.?\.PFL
        fi
}


yast_popup () {
	# open a YaST popup with the given text
	local tmpfile

        tmpfile="${TMPDIR}/yast_popup.ycp"

	cat > ${tmpfile} <<-EOF
		{
			import "Popup";
			Popup::AnyTimedMessage ( "", "$1", 10 );
		}
EOF

	[ -x /sbin/yast2 ] && /sbin/yast2 ${tmpfile}
	rm ${tmpfile}
}


yast_popup_timed () {
	# open a YaST popup with the given text
	local tmpfile

        tmpfile="${TMPDIR}/yast_popup.ycp"

	cat > ${tmpfile} <<-EOF
		{
			import "Popup";
			Popup::ShowTextTimed ( "Information", "$1", 10 );
		}
EOF

	[ -x /sbin/yast2 ] && /sbin/yast2 ${tmpfile}
	rm ${tmpfile}
}


yast_popup_wait () {
	# open a YaST popup with the given text and wait for user input
        # used for program termination message
	local tmpfile

	tmpfile="${TMPDIR}/yast_popup_wait.ycp"

	cat > ${tmpfile} <<-EOF
		{
			import "Popup";
			Popup::AnyMessage ( "Program Termination", "$1");
		}
EOF

	[ -x /sbin/yast2 ] && /sbin/yast2 ${tmpfile}
	rm ${tmpfile}
}


cleanup() {
  if [ ! -e /root/sap-install-do-not-rm ]; then

    # Cleanup
    # SAPINST automatically creates the directory /tmp/sapinst_exe.*
    rm -rf /tmp/sapinst_exe.*
    rm -f  ${SAPINST_DIR}/ay_*
    # the ^[ is a escape character "strg-v ESC" !! don't cut'n'paste it

    rm -rf ${SAPCD_INSTMASTER}
    # delete since created via mktemp
    rm -rf ${TMPDIR}

    # check if we stopped nscd during our installation
    [ "${NSCD_RUNNING}" = "true" ] && service nscd start > /dev/null 2>&1
  fi
}


###########################################
# Main
###########################################

###########################################
# check prerequisites
###########################################
# required for further initialization of sapinst workflow
[ -z $SAPINST_PRODUCT_ID ] && usage && echo "You must specify a SAPINST Product ID." && yast_popup_wait "You must specify a SAPINST Product ID. Exiting." && exit $ERR_missing_entries
[ -n "${SAPINST_PRODUCT_ID//[0-9A-Za-z_:.]/}" ] && echo "This does not look like a SAPINST Product ID: ${SAPINST_PRODUCT_ID}." && yast_popup_wait "This does not look like a SAPINST Product ID: ${SAPINST_PRODUCT_ID}. Exiting." && exit $ERR_missing_entries

[ -z $SAPCD_INSTMASTER ] && usage && echo "You must specify the full qualified path to the SAP Installation Master medium." && yast_popup_wait "You must specify the full qualified path to the SAP Installation Master medium." && exit $ERR_missing_entries
[ ! -x ${SAPCD_INSTMASTER}/sapinst ] && usage && echo "Could not find the sapinst executable in the given path (${SAPCD_INSTMASTER})." && yast_popup_wait "Could not find the sapinst executable in the given path (${SAPCD_INSTMASTER})." && exit $ERR_missing_entries

# check for root rights
if [ $(id -u) != "0" ]; then
        echo -e "You need to be root (uid=0) to start this program"
        do_exit ${ERR_no_suid}
fi


# disabling nscd during installation because of BZ 639753
# check if started at all
NSCD_RUNNING="false"
service nscd status > /dev/null 2>&1
[ $? -eq 0 ] && service nscd stop > /dev/null 2>&1 && NSCD_RUNNING="true"


###########################################
# Get input
###########################################

# fake_hostname e.g. aiohost
virt_hostname=""
if [ -f ${A_VIRTHOSTNAME} ]; then
        virt_hostname=$(< ${A_VIRTHOSTNAME})
fi


# System "T-Shirt size"
TSHIRT="M"
[ -f ${A_TSHIRT} ] && TSHIRT=$(< ${A_TSHIRT})

# CACHE_SIZE in MB
main_memory_KB=$(awk -F" " '{if (match ($1,"^MemTotal")) print $2}' /proc/meminfo)
main_memory_MB=$(( ${main_memory_KB} / 1024 ))
# rounding to full 1024 MegaBytes
main_memory_MB=$(( ( $main_memory_MB + 1024 ) / 1024 * 1024 ))
# set DBMEM to (RAM - 4GB) during load phase
DBMEM=$(( ${main_memory_MB} - 4096 ))
# fall back to SAPINST defaults in case of small amount of RAM
[ 1025 -gt ${DBMEM} ] && DBMEM=""

# MaxDB MAXCPU
DBCPU=$(( $(grep -c processor /proc/cpuinfo) - 1 ))
# amount of available (cpu -1)
[ 1 -gt ${DBCPU} ] && DBCPU=1

# Amount of parallel load jobs
#LOADJOBS=$(( $(grep -c processor /proc/cpuinfo) * 2 ))
# minimum of 4 parallel load jobs
#[ 4 -gt ${LOADJOBS} ] && LOADJOBS=4
LOADJOBS=1

SID=$( gawk -F"=" '/NW_GetSidNoProfiles.sid/ { print $2 }' ${SAPINST_DIR}/inifile.params | sed 's/^ //g' )
DBSID=$( gawk -F"=" '/getDBInfo.dbsid/ { print $2 }' ${SAPINST_DIR}/inifile.params | sed 's/^ //g' )

echo "####################################################"
echo "# Installation Parameters "
echo "####################################################"
echo
echo "SAPINST_PRODUCT_ID=  $SAPINST_PRODUCT_ID"
echo "SAPCD_INSTMASTER=    $SAPCD_INSTMASTER"
echo
echo "virt_hostname=       $virt_hostname"
echo "virt_ip_pool=        $virt_ip_pool"
echo "virt_ip_netmask=     $virt_ip_netmask"
echo "REAL_HOSTNAME=       $REAL_HOSTNAME"
echo "TSHIRT=              $TSHIRT"
echo
echo "SAP_SID=             $SID"
echo
echo "DBSID=               $DBSID"
echo "DBMEM=               $DBMEM"
echo "DBCPU=               $DBCPU"
echo "DBTYPE=              $DBTYPE"
echo
echo "INSTALL_COUNT=       $INSTALL_COUNT"
echo
echo "####################################################"

#################################################################
# End Get Input
#################################################################


###########################################
# Prepare Installation
###########################################

echo "Starting sshd..."
service sshd start

create_sapstartsrv_resources

###########################################
# Database specific preparations
###########################################

if [ "DB6" = "${DBTYPE}" ]; then
	# comment "fis" service in /etc/services, as DB6 needs port 5912 as DB2 communication service
	sed -i 's@.*5912/.*@# & # changing as needed for DB2 communication service@' /etc/services
fi

if [ -d /sapdata ]; then
	case "${DBTYPE}" in
	ADA)
        	echo "Linking data volumes of system ${DBSID} to data partition (/sapdata/${DBSID}/sapdata)."
        	mkdir -p /sapdata/${DBSID}/sapdata
        	mkdir -p /sapdb/${DBSID}/
        	ln -s /sapdata/${DBSID}/sapdata /sapdb/${DBSID}/sapdata
		;;
	DB6)
        	echo "Linking '/sapdata' to '/db2/${DBSID}/sapdata'."
        	mkdir -p /sapdata/${DBSID}/
        	mkdir /sapdata/${DBSID}/sapdata1 /sapdata/${DBSID}/sapdata2 /sapdata/${DBSID}/sapdata3 /sapdata/${DBSID}/sapdata4
        	# link to sapdata filesystem
        	mkdir -p /db2/${DBSID}
        	ln -s /sapdata/${DBSID}/sapdata1  /db2/${DBSID}/sapdata1
        	ln -s /sapdata/${DBSID}/sapdata2  /db2/${DBSID}/sapdata2
        	ln -s /sapdata/${DBSID}/sapdata3  /db2/${DBSID}/sapdata3
        	ln -s /sapdata/${DBSID}/sapdata4  /db2/${DBSID}/sapdata4
		;;
	ORA)
        	echo "Linking data volumes of system ${DBSID} to data partition (/oracle/${DBSID}/sapdata)."
        	mkdir -p /sapdata/${DBSID}/sapdata
        	mkdir -p /oracle/${DBSID}/
        	ln -s /sapdata/${DBSID}/sapdata /oracle/${DBSID}/sapdata
		;;
	SYB)
        	echo "Linking data volumes of system ${DBSID} to data partition (/sybase/${DBSID}/sapdata)."
        	mkdir -p /sapdata/${DBSID}/sapdata
        	mkdir -p /sybase/${DBSID}/
        	ln -s /sapdata/${DBSID}/sapdata /sybase/${DBSID}/sapdata_1
		;;
	esac
fi

# set virtual hostname
if [ "${virt_hostname}" ] ; then
	create_virt_interface
fi

# Disable SAP Installation Prerequisite Checker due to saplocales
export PRC_DEACTIVATE_CHECKS=true

####################################################################
# Start the SAP installation
#

cd ${SAPINST_DIR}
SAPINST_CMD="${SAPCD_INSTMASTER}/sapinst \
	SAPINST_EXECUTE_PRODUCT_ID=${SAPINST_PRODUCT_ID} \
	SAPINST_SKIP_SUCCESSFULLY_FINISHED_DIALOG=true \
	SAPINST_INPUT_PARAMETERS_URL=${SAPINST_DIR}/inifile.params \
	SAPINST_START_GUISERVER=false "

if [ -e ${SAPINST_DIR}/ay_q_virt_hostname ]; then
	SAPINST_CMD="$SAPINST_CMD SAPINST_USE_HOSTNAME=${virt_hostname} "
fi

if [ "TREX_INSTALL:GENERIC.IND.PD" != "${SAPINST_PRODUCT_ID}" ]; then
#	# run in dark installation mode - without SAPINST GUI
	SAPINST_CMD="$SAPINST_CMD SAPINST_SKIP_DIALOGS=true"
fi

# run SAPINST
${SAPINST_CMD}
SAPINST_RETURN_VALUE=$?

# ignore return code if installationSuccesfullyFinished.dat can be found
while [ 0 -ne ${SAPINST_RETURN_VALUE} ] && [ ! -f ${SAPINST_DIR}/installationSuccesfullyFinished.dat ]; do
        # SAPINST crashed?
        echo "It seems as if the SAP installation crashed? This should not happen..."
        yast_popup_wait "The SAP installation seems to have crashed...\nCheck the log files in '${SAPINST_DIR}'\nor /var/adm/autoinstall/logs/sap_inst.log\nand try to fix the problem manually.\n\nAfterwards press <OK> to restart the SAP installation tool."

        # TODO Restart SAPINST directly without asking whether to reuse existing files or not...
        #        ${SAPINST_CMD}
        # Therefore remove SAPINST_INPUT_PARAMETERS_URL=<value> so SAPINST_PARAMETER_CONTAINER_URL=inifile.xml can be called directly again
        SAPINST_CMD=$(echo ${SAPINST_CMD} | sed 's/\(SAPINST_INPUT_PARAMETERS_URL.*\) //')
        SAPINST_CMD="${SAPINST_CMD} SAPINST_PARAMETER_CONTAINER_URL=${SAPINST_DIR}/inifile.xml"
        SAPINST_RETURN_VALUE=$?
done

# continue - SAPINST finished with return code 0

# Cleanup-PopUp
yast_popup "SAPINST finished.\nCleaning up and starting SAP system."

adapt_sap_instance_profile

# remove additional env files
#rm ~${sid}adm/.sapenv_*
rm -f $(eval echo ~"${sid}"adm)/.sapenv_*
rm -f $(eval echo ~"${sid}"adm)/.sapsrc_*

# restart SAP system to activate changed settings
su -c "stopsap ${virt_hostname}" -l ${sid}adm

case ${DBTYPE} in
        ADA )   # MaxDB (ADA)
                adapt_maxdb_settings
        ;;
        DB6 )   # DB2 LUW (DB6)
                adapt_db6_settings
        ;;
        SYB )   # Sybase ASE (SYB)
                adapt_sybase_settings
        ;;
#        * )     # MaxDB
#                adapt_maxdb_settings
#        ;;
esac

su -c "startsap ${virt_hostname}" -l ${sid}adm

echo "Installation successfully completed!"
# yast_popup "Installation successfully completed!"
#installation_summary

cleanup

exit ${SAPINST_RETURN_VALUE}

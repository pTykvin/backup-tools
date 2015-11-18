#!/bin/bash

# VMrestore
# version = '0.2';

# РћРіСЂР°РЅРёС‡РµРЅРёСЏ
# 1) РїРѕРґ Р±Р»РѕС‡РЅС‹РјРё СѓСЃС‚СЂРѕР№СЃС‚РІР°РјРё РїРѕРЅРёРјР°РµС‚СЃСЏ lvm
# 2) Р’ РЅР°Р·РІР°РЅРёРё vg РЅРµ РґРѕР»Р¶РЅРѕ Р±С‹С‚СЊ С‚РёСЂРµ

# Patch to lofile
#logPath=/samba/anonymous/backup/start/vmrestore.log

# Email recipient of errors, logs...
email=

# Options to pass to DD (when copying snapshots)
ddOptions="bs=100M conv=notrunc"

# Actual location on the storage server
srcRestore="/share/backup/start"

# Compress transfer with LZO
lzop="lzop -dc"

# Create lv if not exists
force=yes

# start after restore
startAfterRestore=no

# Subroutine to print and log 
_log () {
        echo $1|tee -a $logPath
}

_error() {
	_log "ERROR: $1"
	_log "---------------------------------"
#	echo "ERROR: $1" |mail -s "ERROR: $1 on $(hostname)" $email
	exit 1
}

_complete() {
	_log "Restore complete: $guest @ $(date)"
	_log "---------------------------------"
	exit 0
}

_run(){
	return `LANG=C virsh domstate $guest >/dev/null 2>&1 |grep -c run`
}

_restoreDisk(){
        _log "Restore $disk -> $destDisk"
        #$lzop "$srcRestore/$disk.lzo" > "$destDisk"  2>/dev/null
        $lzop "$srcRestore/$disk.lzo" > "$destDisk"
        if [ $? -ne 0 ]; then
                _error "restore disk $disk on $guest, vm not restore"
        fi
}

[ -f "$1" ] && source $1

#touch $logPath
startTime=$(date)
guest=$(virsh domxml-to-native qemu-argv $(ls $srcRestore/*.xml) |sed -r 's/.*-name ([^ ]*).*/\1/')
_log "Restore $guest started $(date)"
if ! _run ;then
	_error "Guest $guest is run, not restored"
fi

virsh define $(ls $srcRestore/*.xml) >/dev/null 2>&1
if [ $? -ne 0 ]; then
	_error "domain $guest not define!"
fi

diskAll=$(ls $srcRestore/*.lzo)
while read disk
do
	disk=$(basename $disk .lzo)
	destDisk=$(virsh domblklist $guest --details|sed -rn "/\/$disk$/s/[^\/]*(.*$disk)/\1/p")
	if [ $(virsh domblklist $guest --details|sed -rn "/$disk$/s/(^[^ ]*).*/\1/p") == "block" ]; then
		lvdisplay $destDisk >/dev/null 2>&1
		if [ $? -ne 0 ] ; then 
			if [ "$force" != "yes" ] ; then
				_error "Logical volume does not exists, guest $guest not restore"
			fi	
			vgName=$(echo $destDisk|sed -nr '/mapper/s/.*\/(.*)-.*/\1/p;s/\/dev\/(.*)\/.*/\1/p')
        		lvName=$(echo $destDisk|sed -nr '/mapper/s/.*-(.*)/\1/p;s/\/.*\/.*\/(.*)/\1/p')
			lvSize=$(lzop -l  $srcRestore/$disk.lzo|awk '{ print $3}'|tail -n 1)
			lvcreate $vgName -n $lvName -L "$lvSize"b >/dev/null 2>&1
			if [ $? -ne 0 ]; then 
				_error "Logical volume not create, vm $guest not restore" 	
			fi
		elif [ -n "lvdisplay $destDisk 2>&1|grep 'NOT available'" ]; then
			lvchange -a y $destDisk
			if [ $? -ne 0 ] ; then
				_error "Logical volume NOT available, guest $guest not restore"
			fi	
		fi
	else
		if [ ! -d "$(dirname $destDisk)" ]; then 
			if [ "$force" != "yes" ] ; then
                                _error "Directory for vm disk not exists, guest $guest not restore"
                        fi
			mkdir -p $(dirname $destDisk) 2>/dev/null
			if [ $? -ne 0 ]; then
                                _error "Directory for vm disk not exists and not create, guest $guest not restore"
                        fi
		fi
	fi
	_restoreDisk	
done <<EOF
$diskAll
EOF
if [ -n "$(ls $srcRestore/*.vmstate 2>/dev/null)" ]; then
	_log "Restore state guest $guest"
	virsh restore $(ls $srcRestore/*.vmstate) >/dev/null 2>&1
        if [ $? -ne 0 ]; then
	        _error "guest $guest not restore vm state!"
	fi
else
	if [ $startAfterRestore == "yes" ] ;then 
		_log "Start guest $guest"
		virsh start $guest >/dev/null
        	if [ $? -ne 0 ]; then
		        _error "guest $guest not start after restore"
		fi
	fi
fi
_complete

#!/bin/bash

# VMsnapshot
# Copyright 2013 Ryan Babchishin <rbabchishin@win2ix.ca> http://www.win2ix.ca
# version = '0.8';

#begin GPL
#    This file is part of VMsnapshot.
#
#    VMsnapshot is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, version 3 of the License.
#
#    VMsnapshot is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with VMsnapshot.  If not, see <http://www.gnu.org/licenses/>.
#end GPL
# use kernel.sysrq = 1 and save_image_format = "lzop" ( in qemu.conf )  
export PATH=/sbin:$PATH

# Patch to lofile
logPath=/var/log/vmbackup

# Less intrusive if you disable state saving 
# at the expense of an inconsistent filesystem
saveState=yes

# For testing
guest=""

# Snapshots will not grow larger than this
snapshotSize=5G

# Email recipient of errors, logs...
email=root

# Dump xml domain definition
dumpDomain=yes

# Shutdown guest before backup
shutdownGuest=no

# Command to shutdown guest
shutdownCommand=""

# Disk to exclude in backup
excludeDisk="
"

# Start guest after backup
startGuestAfterBackup=yes

# What sleep guest shutdown in seconds
sleepShutdown=30
sleepCount=5

# Options to pass to DD (when copying snapshots)
ddOptions="bs=100M conv=notrunc"

# Actual location on the storage server
backupDest="/opt/backup/vm_states"

# Compress transfer with LZO
lzop="lzop -c -1"

# Subroutine to print and log 
_log () {
	if [ -z "logPath" ]; then
 	        echo ""
	else
	        echo $1 >> $logPath
	fi
}

_error() {
        _log "ERROR: $1"
        _log "---------------------------------"
#       echo "ERROR: $1" |mail -s "ERROR: $1 on $(hostname)" $email
        exit 1
}

_warning() {
        _log "WARNING: $1"
        echo "WARNING: $1" |mail -s "WARNING: $1 on $(hostname)" $email
	warning=1
}

_sync(){
	# Sync guest storage (incase we don't save state)
	virsh send-key $guest KEY_LEFTALT KEY_SYSRQ KEY_S 1>/dev/null
	sleep 10
}

_run(){
	return `LANG=C virsh domstate $guest |grep -c run`
}

_lvmBackup(){
	echo "$excludeDisk"| grep "$disk$" 2>/dev/null 1>/dev/null
	if [ $? -ne 0 ]; then
		lvPath=$(lvdisplay $disk|sed -n 's/LV Path//p')
		vgPath=$(echo $lvPath| cut -d'/' -f1-3)
		lvName=$(basename $lvPath)
		snapshotName=${lvName}_backup
		#lvs $lvPath -o lv_size --units b|sed -n '$p' >$backupDir/$lvName.size
		_log "Snapshot: $lvPath -> $snapshotName"
        	lvcreate --snapshot $lvPath -n $snapshotName --size $snapshotSize -p r 1>/dev/null
        	if [ $? -eq 0 ]; then {
        	        # Record that the snapshot was created
        	        snapshots=( "${snapshots[@]}" "$vgPath/$snapshotName" )
        	} else {
			_warning "Please remove potentialy stale backup snapshot: $disk in $guest skipping"
        	} fi
	else		
		_log "Disk $disk on $guest exclude!"
	fi
}

_backupDisk(){
	_log "Transfer (dd+lzop): $disk -> $backupDir/$(basename $disk _backup).lzo"
	dd if=$disk $ddOptions | pv -s $(du -sb $disk | grep -o '^[0-9]*') -pe --name "Упаковка /images/sco.qcow2" | $lzop > $backupDir/$(basename $disk _backup).lzo
	if [ $? -ne 0 -o ${PIPESTATUS[0]} -ne 0 ]; then 
		_warning "disk $disk on $guest not backup!"
	fi
}

_saveState(){
	if [ "$1" == restore ]; then
		# Resume the guest
		_log "Restoring guest state $guest"
		virsh restore $backupDir/$guest.vmstate 1>/dev/null
		if [ $? -ne 0 ]; then 
			_error "$guest is probably down. Error restoring $backupDir/$guest.vmstate"
		fi
		stateEndTime=$(date +%s)
		# Show how long the guest was down for
		_log "Guest $guest been restored to previous state: $(date)"
		_log "Guest $guest suspend $(($stateEndTime-$stateTime)) sec"
	else	
		if _run $guest ;then 
			_error "Guest $guest not run, livesnapshot not created"
		fi
		_log "Guest $guest going down for state save now: $startTime"
		# sync filesystem
		_sync
		# Get time of the state save (or begin of snapshots)
	        stateTime=$(date +%s)
		# Save guest state and leave it in a stopped state
		virsh save $guest $backupDir/$guest.vmstate --running 1>/dev/null
		if [ $? -ne 0 ]; then 
			_error "save $guest may have failed, backup not completed"
		fi
	fi
}

_backupDomain(){
	if [ $dumpDomain == "yes" ]; then
		virsh dumpxml $guest --migratable > $backupDir/$guest.xml
		if [ $? -eq 0 ]; then {
                	_log "Dump xml domain definition to $backupDir/$guest.xml"
                } else {
                        _error "Not a dump xml domain definition: $guest "
                } fi
	fi
} 

if [ -f "$1" ];then 
	source $1
	if [ -z "$guest" ];then
		vm=$(basename $1)
		guest=${vm//[^0-9-_.a-zA-Z]/}
	fi
fi

warning=0
touch $logPath
if ! `LANG=C virsh domstate $guest >/dev/null 2>&1` ;then
        _error "Guest $guest not exists, backup not created"
fi
_log "$guest backup started $(date)"
backupDir=$backupDest
mkdir -p $backupDir
# Time the process
startTime=$(date)
if [ -n "$(virsh domblklist $guest --details|awk '/disk/ && /file/')" ]; then
	_log "Disk in guest $guest in file raw format, vm shutdown!"
	shutdownGuest=yes 
fi

#cold backup
if [ $shutdownGuest == "yes" ]; then
	if ! _run; then
	        count=0
		stateTime=$(date +%s)
		if [ -z "$shutdownCommand" ];then
		        virsh shutdown $guest >/dev/null 2>&1
		else
			eval $shutdownCommand
		fi
	        while ! _run
	        do
	                sleep $sleepShutdown
	                count=$((count+1))
	                if [ $count -gt $sleepCount ]; then
				_error "Guest $guest does not shutdown by acpi!"
			fi
	        done
	fi
	for disk in $(virsh domblklist $guest --details |awk '/disk/ { print $4}'); do 
		echo "$excludeDisk"| grep "$disk$" 2>/dev/null 1>/dev/null
		if [ $? -ne 0 ]; then
			_backupDisk
		else		
			_log "Disk $disk on $guest exclude!"
		fi
	done
	_backupDomain	
	if [ $startGuestAfterBackup == "yes" ]; then 
		virsh start $guest >/dev/null
		if [ $? -ne 0 ]; then
			_error "Guest $guest not start after backup!"
		fi
		stateEndTime=$(date +%s)
		_log "Guest $guest shutdown $((10#$stateEndTime-10#$stateTime)) sec"
	fi
#hot backup
else
	if [ $saveState == 'yes' ] ; then
		_saveState
	else
		_log "State saving is disabled, snapshots will be inconsistent"
	fi
		
	for disk in $(virsh domblklist $guest --details |awk '/disk/ { print $4}'); do
		_lvmBackup
	done
	[ $saveState == 'yes' ] && _saveState restore 
	
	# Send each snapshot for this guest that was taken
	for disk in ${snapshots[@]} ; do 
		lvdisplay $disk | grep 'LV snapshot status' >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			_backupDisk
		  _log "Removing snapshot $disk"
		  lvremove -f $disk 1>/dev/null || _warning "Snapshot $disk not removed"
		else
			_warning "ERROR, Not a snapshot: $disk (BAD), skipping..."
		fi	
	done
	_backupDomain	
	unset snapshots
fi
if [ "$warning" == "1" ]; then
	_log "WARNING: See logs, $guest @ $(date)"
	exit 255
else
	_log "Backup complete: $guest @ $(date)"
	_log "---------------------------------"
	exit 0
fi

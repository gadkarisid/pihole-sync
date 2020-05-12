#!/bin/bash

###########################
### BEGIN CONFIGURATION ###
###########################

# Define PiHole node name
node_name=pihole01

# Designate whether this node is the 'master' or 'slave'
node_type=master

# Local PiHole directory
LOCAL_DIR=/etc/pihole

# Remote Rsync directory
REMOTE_DIR=/media/pihole_sync

###########################
#### END CONFIGURATION ####
###########################

# Create initial syslog entry
logger "pihole_sync: PiHole sync starting"
logger "pihole_sync: Node name is" $node_name

# If this is the master node
if [[ $node_type == "master" ]]; then
	logger "pihole_sync: Node type is master"
	# Files to sync
	FILES=(gravity.db)

	# Sync specified files
	for FILE in ${FILES[@]}
	do
        	# Check if the local file is newer than the remote file
	        if [[ "$LOCAL_DIR/$FILE" -nt "$REMOTE_DIR/$FILE" ]]; then
			logger "pihole_sync:" $FILE "will be synced"
                	# If the local file is newer, then copy it to the remote location
	                cp -u $LOCAL_DIR/$FILE $REMOTE_DIR/$FILE
			logger "pihole_sync:" $FILE "has been copied"
		else
			logger "pihole_sync:" $FILE "does not need to be synced"
	        fi
	done
fi

# If this is the slave node
if [[ $node_type == "slave" ]]; then
	# Pause while the master node completes its sync
	sleep 45

	logger "pihole_sync: Node type is slave"
	# Files to sync
	FILES=(gravity.db)

	# Sync flags
	SYNC=0
	UPDATE_GRAVITY=0

	# Determine whether to sync files
	for FILE in ${FILES[@]}
	do
        	# Check if the remote file is newer than the local file
	        if [[ "$REMOTE_DIR/$FILE" -nt "$LOCAL_DIR/$FILE" ]]; then
        	        # If the remote file is newer, then enable sync
                	((SYNC++))
	                logger "pihole_sync:" $FILE "needs to be synced"
        	else
                	logger "pihole_sync:" $FILE "does not need to be synced"
	        fi
	done

	# Sync files
	if [[ "$SYNC" -ge 1 ]]; then
		for FILE in ${FILES[@]}
	        do
	                cp -u $REMOTE_DIR/$FILE $LOCAL_DIR/$FILE
			logger "pihole_sync:" $FILE "has been copied"
			((UPDATE_GRAVITY++))
	        done
	fi

	# Sync files and update Gravity
	if [[ "$UPDATE_GRAVITY" -ge 1 ]]; then
	        logger "pihole_sync: Restarting DNS resolution"
	        pihole restartdns reload-lists
	fi
fi

logger "pihole_sync: PiHole sync complete"

# Send log file to remote directory
grep "pihole_sync" /var/log/syslog > /home/pi/pihole_sync-$node_name.log
sudo cp -u /home/pi/pihole_sync-$node_name.log $REMOTE_DIR/pihole_sync-$node_name.log

exit 0

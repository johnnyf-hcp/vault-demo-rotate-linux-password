#!/bin/bash

# Default variables
#export SERVER=localhost
export ADMINUSERNAME=root
export SSHPORT=8222

# First check if Vault is running and unsealed
export ISINITIALIZED=$(vault read -field=initialized sys/health)
if [ "$ISINITIALIZED" == "false" ]
then
    echo "Vault is not initialized.  Stopping rotation job."
    exit
fi
export ISSEALED=$(vault read -field=sealed sys/health)
if [ "$ISSEALED" == "true" ]
then
    echo "Vault is still sealed.  Stopping rotation job."
    exit
fi

# Retrieve list of host to rotate
# This will read each line with or without any new line at the end of the file
while read SERVER || [[ -n $SERVER ]]; do
    # If empty, go to next line
    if [ -z "$SERVER" ]
    then
        continue
    fi
    
    echo "Rotating password on server: $SERVER"
    # The SSHPASS environment variable will be used by sshpass later as the password using the -e flag
    export SSHPASS=$(vault kv get -field=admin-password -mount=secret $SERVER)
    # Check if empty value
    if [ -z "$SSHPASS" ]
    then
        echo "No value found in Vault - set to default root password \"root\""
        export SSHPASS=root
    else
        # For debugging. Comment this out in production.
        echo "Current password for server $SERVER is $SSHPASS"
    fi
    # Generate new password
    export NEWADMINPASS=$(vault write -field=random_bytes sys/tools/random/32 format=base64)
    # Check for error
    if [ ! $? -eq 0 ]
    then
        echo "Unable to generate new password"
        break
    fi

    # For debugging. Comment this out in production.
    echo "New password is: $NEWADMINPASS"
    # Update new password into Vault first.  
    # In the event the change password fails, we will rollback to the previous version.
    echo $NEWADMINPASS | vault kv put -mount=secret $SERVER admin-password=-
    # Check if new password was stored successfully before proceeding
    if [ ! $? -eq 0 ]
    then
        echo "Unable to insert new password into Vault for server: $SERVER.  Exiting."
        break
    fi
    
    # Successfully stored the new password in Vault as a new version, proceed to change password on specified host
    # SSH into server and change password
    #sshpass -p "root" ssh -o StrictHostKeyChecking=no -p 8222 root@localhost << EOF
    #echo -e "root2\nroot2" | passwd root
    #EOF
    echo "Stored new password for server: $SERVER"
    sshpass -e ssh -o StrictHostKeyChecking=no -p $SSHPORT $ADMINUSERNAME@$SERVER << EOF
echo -e "$NEWADMINPASS\n$NEWADMINPASS" | passwd $ADMINUSERNAME
EOF
    # If it fails $? will not be 0, will return 5
    if [ $? -eq 0 ]
    then # Success, store the new password
        echo "Succeeded in rotating password for server: $SERVER"
    else # Failed, rollback to the last known version
        # Get last version
        export CURR_VERSION=$(vault kv metadata get -format=json -mount=secret $SERVER  | jq ".data.current_version")
        echo "Current version is: $CURR_VERSION"
        # If more than one version, roll back to the previous version
        if [ $CURR_VERSION -gt 1 ]
        then
            # Rollback to the last version
            export PREV_VERSION=$((CURR_VERSION - 1))
            echo "Rolling back to version $PREV_VERSION"
            vault kv rollback -mount=secret -version=$PREV_VERSION $SERVER
        fi

    fi
    echo
done <hostlist.txt


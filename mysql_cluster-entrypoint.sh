#!/bin/bash
set -e

if [ -z "$NODE_TYPE" ]; then 
	echo >&2 'error: Cluster node type is required'
        echo >&2 '  You need to specify NODE_TYPE with a possible value of sql, management, or data'
        exit 1
fi

# If we're setting up a mysqld/SQL API node 
if [ "$NODE_TYPE" = 'sql' ]; then

        echo
        echo 'Setting up node as a new MySQL Cluster data node'
        echo

        # we need to ensure that they have specified and endpoint for an existing management server
        if [ ! -z "$MANAGEMENT_SERVER" ]; then
                echo >&2 'error: Cluster management server is required'
                echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname>[:<port>] in order to setup this new data node'
                exit 1
        fi

	# Get config
	DATADIR="$("$@" --verbose --help --log-bin-index=/tmp/tmp.index 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi
		# If the password variable is a filename we use the contents of the file
		if [ -f "$MYSQL_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(cat $MYSQL_ROOT_PASSWORD)"
		fi
		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo 'Initializing database'
		"$@" --initialize-insecure=on
		echo 'Database initialized'

		"$@" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		mysql_tzinfo_to_sql /usr/share/zoneinfo | "${mysql[@]}" mysql
		
		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwmake 128)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys');
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi
		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)  echo "$0: running $f"; . "$f" ;;
				*.sql) echo "$0: running $f"; "${mysql[@]}" < "$f" && echo ;;
				*)     echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	chown -R mysql:mysql "$DATADIR"


	echo
	echo "Registering new MySQL process with existing management server: $MANAGEMENT_SERVER"
	echo
    
        # here we need to "register" this instance with the management server by adding it to its config file
        #[MYSQLD]
        #NodeId=<node ID>
        #HostName=<IP/hostname>

        # and we need to add the management server info to this mysqld instance's my.cnf file
        #ndb_nodeid=<management node ID>
        #ndb_connectstring=<management_server>:<port>
     
	exec "$@"

# If we're setting up a management node 
elif [ "$NODE_TYPE" = 'management' ]; then
	echo
	echo 'Setting up node as a new MySQL Cluster management node'
	echo

        # if they're bootstrapping a new cluster, then we just need to start with a fresh Cluster
	if [ ! -z "$BOOTSTRAP" ]; then
		echo
		echo 'Bootstrapping new Cluster with a fresh management node'
		echo

	# otherwise we need to ensure that they have specified endpoint info for an existing ndb_mgmd node 
	elif [ ! -z "$MANAGEMENT_SERVER" ]; then
		echo
		echo "Adding new management node and registering it with the existing server: $MANAGEMENT_SERVER"
		echo

        else
     		echo >&2 'error: Cluster management node is required'
		echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname>[:<port>] in order to add a new managmeent node, or you must specify BOOTSTRAP in order to create a new Cluster'
      		exit 1

        fi
   

# If we're setting up a data node 
elif [ "$NODE_TYPE" = 'data' ]; then
	echo
	echo 'Setting up node as a new MySQL Cluster data node'
	echo

	# we need to ensure that they have specified endpoint info for an existing ndb_mgmd node 
	if [ ! -z "$MANAGEMENT_SERVER" ]; then
     		echo >&2 'error: Cluster management server is required'
		echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname>[:<port>] in order to setup this new data node'
      		exit 1
	fi

        # we need to then modify the cluster config on the management server(s) and add the basic defintion:
	#[NDBD]
	#NodeId=<node ID>
	#HostName=<IP/hostname>

        # then we'll start an ndbmtd process in this container 

else 
	echo
	echo 'Invalid node type set. Valid node types are sql, management, and data.'
	echo
fi

exit


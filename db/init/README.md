# db/init/ - MySQL Initialization Scripts

This directory is mounted into the MySQL container as /docker-entrypoint-initdb.d/

Any .sql or .sh files placed here will be executed automatically the FIRST TIME
the MySQL container starts (i.e., when the volume is empty / fresh install).

The IIQ schema scripts are handled by the entrypoint.sh in the iiq-tomcat container,
so this folder is reserved for any additional pre-init SQL you need
(e.g., creating extra databases, users, or grants).

Example file you could add here:
  01-extra-grants.sql  →  GRANT ALL ON *.* TO 'identityiq'@'%';

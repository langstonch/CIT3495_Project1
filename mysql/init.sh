#!/bin/sh
# Runs once on first start of an empty data volume. Passwords come from env, never from this file.
set -e
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" <<SQL
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  password_hash VARCHAR(100) NOT NULL
);
CREATE TABLE IF NOT EXISTS measurements (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user VARCHAR(64) NOT NULL,
  category VARCHAR(64) NOT NULL,
  value DOUBLE NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_category (category)
);
CREATE USER 'auth'@'%' IDENTIFIED BY '$AUTH_DB_PASSWORD';
GRANT SELECT, INSERT ON $MYSQL_DATABASE.users TO 'auth'@'%';
CREATE USER 'enterdata'@'%' IDENTIFIED BY '$ENTERDATA_DB_PASSWORD';
GRANT INSERT ON $MYSQL_DATABASE.measurements TO 'enterdata'@'%';
CREATE USER 'analytics'@'%' IDENTIFIED BY '$ANALYTICS_DB_PASSWORD';
GRANT SELECT ON $MYSQL_DATABASE.measurements TO 'analytics'@'%';
SQL

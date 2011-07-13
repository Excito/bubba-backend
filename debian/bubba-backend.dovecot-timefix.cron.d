*/5 * * * * root /etc/init.d/dovecot status >/dev/null 2>&1 || /etc/init.d/dovecot restart

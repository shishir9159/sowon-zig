# Ashurbanipal



## installation

For Red Hat Enterprise Linux 9.4 (Plow) and kernel version 5.14.0-427.76.1.el9_4.x86_64:

```Bash
# Install the repository RPM:
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Disable the built-in PostgreSQL module:
sudo dnf -qy module disable postgresql

# Install PostgreSQL:
sudo dnf install -y postgresql18-server

# Optionally initialize the database and enable automatic start:
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable postgresql-18
sudo systemctl start postgresql-18
```

## Post-installation

Due to policies for Red Hat family distributions, the PostgreSQL installation will not be enabled for automatic start or have the database initialized automatically. Following steps will: 

```Bash
postgresql-setup --initdb
systemctl enable postgresql.service
systemctl start postgresql.service
```



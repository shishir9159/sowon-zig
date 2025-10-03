# Ashurbanipal


## installation

For Red Hat Enterprise Linux 9.4 (Plow) and kernel version 5.14.0-427.76.1.el9_4.x86_64:

```Bash
# Install the repository RPM:
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Disable the built-in PostgreSQL module:
sudo dnf -qy module disable postgresql

# Install PostgreSQL, developer toolkit(vector), contribution(citext):
sudo dnf install -y postgresql18-server postgresql-devel postgresql18-contrib

# Optionally initialize the database and enable automatic start:
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable postgresql-18
sudo systemctl start postgresql-18
sudo systemctl status postgresql-18
```

```Bash
sudo rpm -i https://ftp.postgresql.org/pub/pgadmin/pgadmin4/yum/pgadmin4-fedora-repo-2-1.noarch.rpm

```

## Post-installation

Due to policies for Red Hat family distributions, the PostgreSQL installation will not be enabled for automatic start or have the database initialized automatically. Following steps will: 

```Bash
postgresql-18-setup initdb
# systemctl enable postgresql.service
# systemctl start postgresql.service
```

sudo yum install pgvector_18

## PG Admin

```Bash
sudo curl https://www.pgadmin.org/static/packages_pgadmin_org.pub | sudo tee /etc/pki/rpm-gpg/pgadmin.asc
sudo rpm --import /etc/pki/rpm-gpg/pgadmin.asc

sudo tee /etc/yum.repos.d/pgadmin4.repo <<EOF
[pgAdmin4]
name=pgAdmin4 Repository
baseurl=https://ftp.postgresql.org/pub/pgadmin/pgadmin4/yum/redhat/rhel-8-x86_64
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/pgadmin.asc
EOF

sudo yum install pgadmin4-web
```


```Bash
bash /usr/pgadmin4/bin/setup-web.sh
```

update the value for DEFAULT_SERVER from '127.0.0.1' to '0.0.0.0' approximately from the /usr/pgadmin4/web/config.py file and restart apache server with the following command:
```Bash
sed

```


# creating user and password

```Bash
sudo -i -u postgres
psql
```

```psql
CREATE ROLE shishir WITH LOGIN PASSWORD 'shishir';
CREATE DATABASE test OWNER shishir;
GRANT ALL PRIVILEGES ON DATABASE test TO shishir;
```

extension "vector"

yum install -y make 
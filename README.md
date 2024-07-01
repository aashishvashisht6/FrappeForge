## For Frappe Docker Image with Custom Apps Creation

### Create a new folder custom_apps 
### In this folder clone all your custom apps.

### docker build -t frappe_custom:1.0 .

### docker-compose up -d

### For New Site Creation

#### bench new-site --no-mariadb-socket --admin-password=admin --db-root-password=admin --install-app erpnext --set-default frontend
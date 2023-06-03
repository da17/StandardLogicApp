locals {
  location = "eastus"

  client_ip = "xx.xx.xx.xx" # get your public IP address, e.g. from  https://whatismyipaddress.com/

  logic_app_name = "uniqueLogicAppName" # this must be globally unique

  storage_account_name = "uniqueStorageAccountName" # this must be globally unique

  storage_subresources = ["blob", "file", "queue", "table"]

  dns_zones = {
    blob = {
      name = "privatelink.blob.core.windows.net"
    },
    file = {
      name = "privatelink.file.core.windows.net"
    }
    queue = {
      name = "privatelink.queue.core.windows.net"
    }
    table = {
      name = "privatelink.table.core.windows.net"
    }
    logic_app = {
      name = "privatelink.azurewebsites.net"
    }
  }
}

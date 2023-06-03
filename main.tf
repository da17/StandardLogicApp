terraform {
  required_version = "1.2.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.28.0"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "logic_app_rg" {
  name     = "logic-app-rg"
  location = local.location
}

resource "azurerm_private_dns_zone" "private_dns_zone" {
  for_each            = local.dns_zones
  name                = each.value.name
  resource_group_name = azurerm_resource_group.logic_app_rg.name
}

resource "azurerm_virtual_network" "logic_app_vnet" {
  name                = "logic-app-vnet"
  address_space       = ["172.16.0.0/25"]
  dns_servers         = ["168.63.129.16"]
  location            = azurerm_resource_group.logic_app_rg.location
  resource_group_name = azurerm_resource_group.logic_app_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "vnet_link" {
  for_each              = local.dns_zones
  name                  = "logic-vnet-${each.key}-link"
  resource_group_name   = azurerm_resource_group.logic_app_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone[each.key].name
  virtual_network_id    = azurerm_virtual_network.logic_app_vnet.id
}

resource "azurerm_subnet" "private_endpoint_snet" {
  name                                          = "pe-snet"
  resource_group_name                           = azurerm_resource_group.logic_app_rg.name
  virtual_network_name                          = azurerm_virtual_network.logic_app_vnet.name
  address_prefixes                              = ["172.16.0.0/27"]
  private_endpoint_network_policies_enabled     = true
  private_link_service_network_policies_enabled = false
}

resource "azurerm_subnet" "logic_app_snet" {
  name                                          = "logic-app-snet"
  resource_group_name                           = azurerm_resource_group.logic_app_rg.name
  virtual_network_name                          = azurerm_virtual_network.logic_app_vnet.name
  address_prefixes                              = ["172.16.0.32/27"]
  private_endpoint_network_policies_enabled     = false
  private_link_service_network_policies_enabled = false

  delegation {
    name = "serverFarms"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_storage_account" "logic_app_storage_account" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.logic_app_rg.name
  location                        = azurerm_resource_group.logic_app_rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = [local.client_ip]
  }
}

resource "azurerm_storage_share" "logic_app_storage_account_share" {
  name                 = "${local.logic_app_name}-content"
  storage_account_name = azurerm_storage_account.logic_app_storage_account.name
  quota                = "5000"
}

resource "azurerm_private_endpoint" "storage_private_endpoints" {
  for_each            = toset(local.storage_subresources)
  name                = "${azurerm_storage_account.logic_app_storage_account.name}-${each.key}-pe"
  location            = azurerm_resource_group.logic_app_rg.location
  resource_group_name = azurerm_resource_group.logic_app_rg.name
  subnet_id           = azurerm_subnet.private_endpoint_snet.id

  private_service_connection {
    name                           = "${azurerm_storage_account.logic_app_storage_account.name}-${each.key}-psc"
    private_connection_resource_id = azurerm_storage_account.logic_app_storage_account.id
    is_manual_connection           = false
    subresource_names              = [each.key]
  }

  private_dns_zone_group {
    name                 = "${each.key}-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone[each.key].id]
  }
}

resource "azurerm_service_plan" "logic_app_service_plan" {
  name                = "logic-app-asp"
  location            = azurerm_resource_group.logic_app_rg.location
  os_type             = "Windows"
  resource_group_name = azurerm_resource_group.logic_app_rg.name
  sku_name            = "WS1"
}

resource "azurerm_logic_app_standard" "logic_app" {
  depends_on                 = [azurerm_private_endpoint.storage_private_endpoints]
  name                       = local.logic_app_name
  resource_group_name        = azurerm_resource_group.logic_app_rg.name
  location                   = azurerm_resource_group.logic_app_rg.location
  app_service_plan_id        = azurerm_service_plan.logic_app_service_plan.id
  virtual_network_subnet_id  = azurerm_subnet.logic_app_snet.id
  storage_account_name       = azurerm_storage_account.logic_app_storage_account.name
  storage_account_access_key = azurerm_storage_account.logic_app_storage_account.primary_access_key
  https_only                 = true
  version                    = "~4"
  app_settings = {
    "WEBSITE_CONTENTOVERVNET" : "1"
    "FUNCTIONS_WORKER_RUNTIME" : "node"
    "WEBSITE_NODE_DEFAULT_VERSION" : "~14"
  }

  site_config {
    use_32_bit_worker_process        = true
    ftps_state                       = "Disabled"
    websockets_enabled               = false
    min_tls_version                  = "1.2"
    runtime_scale_monitoring_enabled = false
    vnet_route_all_enabled           = true
  }
}

resource "azurerm_private_endpoint" "logic_app_private_endpoint" {
  name                = "${azurerm_logic_app_standard.logic_app.name}-pe"
  location            = azurerm_resource_group.logic_app_rg.location
  resource_group_name = azurerm_resource_group.logic_app_rg.name
  subnet_id           = azurerm_subnet.private_endpoint_snet.id

  private_service_connection {
    name                           = "${azurerm_logic_app_standard.logic_app.name}-psc"
    private_connection_resource_id = azurerm_logic_app_standard.logic_app.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }

  private_dns_zone_group {
    name                 = "logic-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone["logic_app"].id]
  }
}

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "2.13.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.54.0"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azurerm" {
  features {}

  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

variable "subscription_id" {
  description = "Azure subscription ID in which to deploy the example."
  type        = string
}

variable "location" {
  description = "Azure region that supports Foundry Agent Service with VNet injection."
  type        = string
}

variable "foundry_name" {
  description = "Globally unique Foundry account name and custom subdomain."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$", var.foundry_name))
    error_message = "Use 2–64 lowercase letters, digits, or hyphens, starting and ending with a letter or digit."
  }
}

resource "azurerm_resource_group" "example" {
  name     = "${var.foundry_name}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "example" {
  name                = "foundry-vnet"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  address_space       = ["10.42.0.0/16"]
}

resource "azurerm_subnet" "agents" {
  name                 = "foundry-agents"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
  address_prefixes     = ["10.42.0.0/24"]

  delegation {
    name = "agent-runtime"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
  address_prefixes     = ["10.42.1.0/24"]
}

resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name      = var.foundry_name
  parent_id = azurerm_resource_group.example.id
  location  = azurerm_resource_group.example.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku  = { name = "S0" }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = var.foundry_name
      publicNetworkAccess    = "Disabled"

      # This integrates agent compute with the customer subnet, not the private endpoint subnet.
      networkInjections = [{
        scenario                   = "agent"
        subnetArmId                = azurerm_subnet.agents.id
        useMicrosoftManagedNetwork = false
      }]
    }
  }
}

resource "azurerm_private_dns_zone" "foundry" {
  for_each = toset([
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
  ])

  name                = each.key
  resource_group_name = azurerm_resource_group.example.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  for_each = azurerm_private_dns_zone.foundry

  name                  = "foundry-vnet-link"
  resource_group_name   = azurerm_resource_group.example.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.example.id
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "foundry-private-endpoint"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "foundry"
    private_connection_resource_id = azapi_resource.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "foundry"
    private_dns_zone_ids = [for zone in azurerm_private_dns_zone.foundry : zone.id]
  }
}

resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = "foundry-project"
  parent_id = azapi_resource.foundry.id
  location  = azurerm_resource_group.example.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = "Foundry VNet Injection"
    }
  }
}

resource "azapi_resource" "agents" {
  type      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview"
  name      = "agents"
  parent_id = azapi_resource.project.id

  # The embedded AzAPI schema omits capabilityHostKind for this preview API.
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind = "Agents"
    }
  }

  depends_on = [
    azurerm_private_endpoint.foundry,
    azurerm_private_dns_zone_virtual_network_link.foundry,
  ]
}

output "foundry_account_id" {
  description = "Resource ID of the Microsoft Foundry account."
  value       = azapi_resource.foundry.id
}

output "foundry_project_id" {
  description = "Resource ID of the Microsoft Foundry project."
  value       = azapi_resource.project.id
}

output "agent_subnet_id" {
  description = "Resource ID of the delegated subnet used for agent network injection."
  value       = azurerm_subnet.agents.id
}

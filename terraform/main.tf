terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

locals {
  location = "eastus"
  prefix   = "app3tier"
}
# In Terraform, while the definition block is plural (locals), references to local values must use the singular prefix local.<name>.  
resource "azurerm_resource_group" "rg" {
  name     = "${local.prefix}-rg"
  location = local.location
}

# --- Azure Key Vault ---
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "${local.prefix}-kv-cheap"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enable_rbac_authorization  = true
}

# --- AKS Cluster (Cost-Optimized) ---
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${local.prefix}-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${local.prefix}-k8s"

  # Identity & Workload Identity enablement
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name       = "systempool"
    node_count = 1
    vm_size    = "Standard_D2as_v7" # Low-cost burstable compute
    os_sku     = "Ubuntu"
  }

  identity {
    type = "SystemAssigned"
  }

  # Add-ons: Azure Key Vault Secrets Store CSI Driver
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
  }
}

# --- Workload Identity Managed Identity & Federation ---
resource "azurerm_user_assigned_identity" "workload_identity" {
  name                = "${local.prefix}-workload-id"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "fic" {
  name                = "${local.prefix}-federated-cred"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.workload_identity.id
  subject             = "system:serviceaccount:default:three-tier-app-api-sa"
}

# Grant Key Vault Secrets User to the Workload Identity
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload_identity.principal_id
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.workload_identity.client_id
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}
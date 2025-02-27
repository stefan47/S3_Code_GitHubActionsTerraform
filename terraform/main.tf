terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.72.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "ws-devops"
    storage_account_name = "cgmsgtf"
    container_name       = "tfstateazdevops"
    key                  = "sgr47.tfstate"
  }
}

provider "azurerm" {
  features {}
}

################################################
# read resource group
################################################

data "azurerm_resource_group" "wsdevops" {
  name = "ws-devops"
}

################################################
# create infra web app
################################################

resource "azurerm_app_service_plan" "sp1" {
  name                = "sgr47-pl"
  location            = data.azurerm_resource_group.wsdevops.location
  resource_group_name = data.azurerm_resource_group.wsdevops.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = "Standard"
    size = "S1"
  }
}

resource "azurerm_app_service" "website" {
  name                = var.web_app_name
  location            = data.azurerm_resource_group.wsdevops.location
  resource_group_name = data.azurerm_resource_group.wsdevops.name
  app_service_plan_id = azurerm_app_service_plan.sp1.id

  site_config {
    linux_fx_version = "NODE|16-lts"
    scm_type         = "LocalGit"
  }
}

################################################
# create infra monitoring
################################################

resource "azurerm_log_analytics_workspace" "log" {
  name                = "sgr47-lg-analytics"
  location            = data.azurerm_resource_group.wsdevops.location
  resource_group_name = data.azurerm_resource_group.wsdevops.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "appi" {
  name                = "sgr47-appi"
  location            = data.azurerm_resource_group.wsdevops.location
  resource_group_name = data.azurerm_resource_group.wsdevops.name
  workspace_id        = azurerm_log_analytics_workspace.log.id
  application_type    = "web"
}

// Skeleton for linking web app and app insights
resource "null_resource" "link_monitoring" {
  provisioner "local-exec" {
    command = <<EOT
      # Login to Azure CLI (Linux operating system assumed)
      az login --service-principal -u $con_client_id -p $con_client_secret --tenant $con_tenant_id
      az webapp config appsettings set --name $web_app_name --resource-group $rg_name --settings APPINSIGHTS_INSTRUMENTATIONKEY=$inst_key APPINSIGHTS_PROFILERFEATURE_VERSION=1.0.0 APPINSIGHTS_SNAPSHOTFEATURE_VERSION=1.0.0 APPLICATIONINSIGHTS_CONNECTION_STRING=$conn_str ApplicationInsightsAgent_EXTENSION_VERSION=~3 DiagnosticServices_EXTENSION_VERSION=~3 InstrumentationEngine_EXTENSION_VERSION=disabled SnapshotDebugger_EXTENSION_VERSION=disabled XDT_MicrosoftApplicationInsights_BaseExtensions=recommended XDT_MicrosoftApplicationInsights_PreemptSdk=disabled
    EOT
    environment = {
      // Parameters needed to login
      con_client_id     = var.client_id
      con_client_secret = var.client_secret
      con_tenant_id     = var.tenant_id
      // Parameters needed for linking
      inst_key          = azurerm_application_insights.appi.instrumentation_key
      conn_str          = azurerm_application_insights.appi.connection_string 
      rg_name           = data.azurerm_resource_group.wsdevops.name
      web_app_name      = var.web_app_name
    }
  }
}
  
data "template_file" "dash-template" {
  template = "${file("${path.module}/dashboard.tpl")}"
  vars = {
    api_name = azurerm_application_insights.appi.name
    rg_name  = data.azurerm_resource_group.wsdevops.name
    sub_id   = var.subscription_id
    query    = "requests | where resultCode != 200 | summarize count()"
  }
}
  
resource "azurerm_dashboard" "my-board" {
  name                = "sgr47-dashboard"
  resource_group_name = data.azurerm_resource_group.wsdevops.name
  location            = data.azurerm_resource_group.wsdevops.location
  tags = {
    source = "terraform"
  }
  dashboard_properties = data.template_file.dash-template.rendered
}

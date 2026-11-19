# TerraformExamples

## Microsoft Foundry with VNet injection

The [`foundry-vnet-injection`](foundry-vnet-injection) example creates a resource
group, a virtual network, and a Microsoft Foundry account and project. The
account's `networkInjections` setting connects Foundry Agent Service to a
dedicated subnet delegated to `Microsoft.App/environments`. This is separate
from the **private endpoint**, which provides inbound access to Foundry on an
undelegated subnet. Public network access is disabled.

The example provisions a basic Agents capability host (preview API). It does
not deploy a model or the Storage, Azure AI Search, and Cosmos DB resources
needed for a Standard Agent setup. To run an agent, deploy a supported model
and access the project from a client that can reach the VNet and resolve its
private DNS names.

### Deploy

Use Terraform 1.6 or later and the Azure CLI. Choose a subscription and
[region that supports Foundry Agent Service with VNet injection](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks).
You need permission to create the resources, and the subscription must have
`Microsoft.CognitiveServices`, `Microsoft.Network`, and `Microsoft.App`
registered. Use a globally unique name for `foundry_name`, which also becomes
the account's custom subdomain.

```sh
cd foundry-vnet-injection
az login
az account set --subscription "<subscription-id>"
export TF_VAR_subscription_id="$(az account show --query id -o tsv)"
export TF_VAR_foundry_name="<globally-unique-foundry-name>"
export TF_VAR_location="eastus2"

terraform init
terraform validate
terraform plan
terraform apply
```

The example uses `10.42.0.0/16`, with `10.42.0.0/24` for agent compute
and `10.42.1.0/24` for private endpoints. If adapting the example for an
existing network, use non-overlapping address ranges and keep the agent
subnet dedicated to this Foundry account and `/27` or larger.

### Verify and clean up

After applying, confirm that Foundry reports `scenario: agent`,
`useMicrosoftManagedNetwork: false`, and a `subnetArmId` matching the
`agent_subnet_id` output:

```sh
az resource show --ids "$(terraform output -raw foundry_account_id)" \
  --api-version 2025-06-01 \
  --query 'properties.networkInjections'
terraform output -raw agent_subnet_id
```

Run `terraform destroy` when finished. Azure can take several minutes to
release the service association on the delegated subnet. If the subnet remains
blocked by the soft-deleted Foundry account and you don't need to recover it,
permanently purge the account, wait for the association to clear, and rerun
`terraform destroy`:

```sh
az cognitiveservices account purge \
  --location "$TF_VAR_location" \
  --resource-group "${TF_VAR_foundry_name}-rg" \
  --name "$TF_VAR_foundry_name"
```

See Microsoft's [basic VNet injection sample](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform/11-private-network-basic-vnet)
for an example that also deploys a model.
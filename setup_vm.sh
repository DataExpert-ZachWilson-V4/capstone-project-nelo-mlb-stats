#!/bin/bash

# Self-setting execute permissions
if [ ! -x "$0" ]; then
  chmod +x "$0"
fi

# Exit immediately if a command exits with a non-zero status.
set -e

# Load environment variables from .env file
if [ -f .env ]; then
  echo "Loading environment variables from .env file..."
  export $(grep -v '^#' .env | xargs)
fi

# Ensure required environment variables are set
required_vars=(RESOURCE_GROUP_NAME STORAGE_ACCOUNT_NAME ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID ARM_SUBSCRIPTION_ID)
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "$var is not set. Please set it in the .env file."
    exit 1
  fi
done

# Directory containing your project
PROJECT_DIR="$(pwd)"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install dependencies if not installed
install_dependencies() {
    if ! command_exists terraform; then
        echo "Terraform is not installed. Installing Terraform..."
        sudo apt-get update
        sudo apt-get install -y gnupg software-properties-common curl
        curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt-get update
        sudo apt-get install -y terraform
    fi

    if ! command_exists az; then
        echo "Azure CLI is not installed. Installing Azure CLI..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg
        curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft-archive-keyring.gpg > /dev/null
        AZ_REPO=$(lsb_release -cs)
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
        sudo apt-get update
        sudo apt-get install -y azure-cli
    fi

    if ! command_exists sshpass; then
        echo "sshpass is not installed. Installing sshpass..."
        sudo apt-get update
        sudo apt-get install -y sshpass
    fi
}

# Logging function to track the time taken by each step
log_and_time() {
    start_time=$(date +%s)
    echo "Starting: $1"
    eval $1
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    echo "Completed: $1 in $elapsed_time seconds"
}

# Install dependencies
log_and_time "install_dependencies"

# Login to Azure CLI using Service Principal
echo "Logging into Azure CLI using service principal..."
if az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"; then
    echo "Successfully logged in to Azure CLI."
else
    echo "Failed to log in to Azure CLI. Check credentials and try again."
    exit 1
fi

# Verify subscription access
echo "Verifying subscription access..."
if [ "$(az account list --query "[?id=='$ARM_SUBSCRIPTION_ID'] | length(@)")" -eq 0 ]; then
    echo "No subscription found with ID $ARM_SUBSCRIPTION_ID. Please check the subscription ID and try again."
    exit 1
else
    echo "Subscription verified."
fi

# Set the Azure subscription
echo "Setting Azure subscription..."
if az account set --subscription "$ARM_SUBSCRIPTION_ID"; then
    echo "Successfully set the subscription."
else
    echo "Failed to set the subscription. Check subscription ID and try again."
    exit 1
fi

# Check if the resource group exists
if az group show --name "$RESOURCE_GROUP_NAME" > /dev/null 2>&1; then
    echo "Resource group $RESOURCE_GROUP_NAME already exists."
else
    echo "Creating resource group $RESOURCE_GROUP_NAME..."
    az group create --name "$RESOURCE_GROUP_NAME" --location "East US"
fi

# Generate SSH key pair if not exists
if [ ! -f id_rsa ] || [ ! -f id_rsa.pub ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f id_rsa -q -N ""
fi

# Export SSH public key for Terraform
export TF_VAR_ssh_public_key=$(cat id_rsa.pub)

# Move the SSH key pair to Terraform directory
cp id_rsa* terraform-azure-vm-setup/

# Initialize Terraform
cd terraform-azure-vm-setup
log_and_time "terraform init"

clean_terraform_state() {
    local resource_type=$1
    local resource_name=$2
    local full_resource_address="${resource_type}.${resource_name}"

    if terraform state list | grep -q "^$full_resource_address$"; then
        echo "Resource $full_resource_address is already managed by Terraform. Removing from state..."
        terraform state rm $full_resource_address
    fi
}

# Clean Terraform state before managing resources
clean_terraform_state "azurerm_resource_group" "main"
clean_terraform_state "azurerm_storage_account" "storage"

# Function to import resource if it exists
import_resource() {
    local resource_type=$1
    local resource_id=$2

    if az resource show --ids "$resource_id" &> /dev/null; then
        echo "$resource_type $resource_id already exists. Importing to Terraform..."
        terraform import $resource_type "$resource_id"
    else
        echo "$resource_type $resource_id does not exist. Creating new resource..."
    fi
}

# Set the resource IDs
RESOURCE_GROUP_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME"
STORAGE_ACCOUNT_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
VNET_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/virtualNetworks/$VIRTUAL_NETWORK_NAME"
SUBNET_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/virtualNetworks/$VIRTUAL_NETWORK_NAME/subnets/$SUBNET_NAME"
NSG_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/networkSecurityGroups/$NETWORK_SECURITY_GROUP_NAME"
NIC_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/networkInterfaces/$NETWORK_INTERFACE_NAME"
VM_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Compute/virtualMachines/$VIRTUAL_MACHINE_NAME"
DISK_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Compute/disks/$DISK_NAME"
CONTAINER_ID="/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME/blobServices/default/containers/$AZURE_CONTAINER"

# Import existing resource if it exists
log_and_time "import_resource azurerm_resource_group.main $RESOURCE_GROUP_ID"

# Apply Terraform plan for VM setup
echo "Creating Terraform plan for VM setup..."
log_and_time "terraform plan -out=tfplan"

echo "Applying Terraform plan for VM setup..."
log_and_time "terraform apply -auto-approve tfplan"

# Check if the .env file exists
if [ ! -f ../.env ]; then
  touch ../.env
fi

# Fetch the public IP output from Terraform
PUBLIC_IP=$(terraform output -raw public_ip)
echo "VM Public IP: $PUBLIC_IP"

# Wait for the VM to be in 'running' state
echo "Waiting for VM to be in 'running' state..."
while [ "$(az vm get-instance-view --name $VIRTUAL_MACHINE_NAME --resource-group $RESOURCE_GROUP_NAME --query "instanceView.statuses[?code=='PowerState/running'] | [0].code" --output tsv)" != "PowerState/running" ]; do
    echo "Waiting for VM to be running..."
    sleep 10
done

# Wait for the SSH port to be available
echo "Waiting for the SSH port to be available..."
while ! nc -z $PUBLIC_IP 22; do
    echo "Waiting for SSH to be available..."
    sleep 10
done

# Connect to the VM and set up Docker, Docker Compose, and other dependencies
ssh -o StrictHostKeyChecking=no -i id_rsa azureuser@$PUBLIC_IP << EOF
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce

# Add user to the Docker group
sudo usermod -aG docker $(whoami)

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install VS Code Server
curl -fsSL https://code-server.dev/install.sh | sh
sudo mkdir -p /etc/systemd/system/code-server@.service.d/
echo -e '[Service]\nEnvironment="PASSWORD=$VS_CODE_PASSWORD"\nExecStart=\nExecStart=/usr/bin/code-server --bind-addr 0.0.0.0:8000' | sudo tee /etc/systemd/system/code-server@.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable --now code-server@$(whoami)

# Install GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# Create project directory if it does not exist
mkdir -p /home/azureuser/projects/capstone-project-nelo-mlb-stats
EOF

# Copy the project files to the VM
rsync -avz --exclude 'terraform-azure-vm-setup/' ../ azureuser@$PUBLIC_IP:/home/azureuser/projects/capstone-project-nelo-mlb-stats

# Start services with Docker Compose on the VM
ssh -o StrictHostKeyChecking=no -i id_rsa azureuser@$PUBLIC_IP << EOF
cd /home/azureuser/projects/capstone-project-nelo-mlb-stats
EOF

echo "Setup complete. You can now access your VM at $PUBLIC_IP"

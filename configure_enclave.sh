# Copyright (c), Mysten Labs, Inc.
# SPDX-License-Identifier: Apache-2.0
#!/bin/bash
# configure_enclave.sh

load_env_file() {
  ENV_FILE=".env"
  if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
  fi
}

# Additional information on this script. 
show_help() {
    echo "configure_enclave.sh - Launch AWS EC2 instance with Nitro Enclaves and configure allowed endpoints. "
    echo ""
    echo "This script launches an AWS EC2 instance (m5.xlarge) with Nitro Enclaves enabled."
    echo "By default, it uses the AMI ami-085ad6ae776d8f09c, which works in us-east-1."
    echo "If you change the REGION, you must also supply a valid AMI for that region."
    echo ""
    echo "Pre-requisites:"
    echo "  - allowed_endpoints.yaml is configured with all necessary endpoints that the enclave needs"
    echo "    access to. This is necessary since the enclave does not come with Internet connection,"
    echo "    all traffics needs to be preconfigured for traffic forwarding."
    echo "  - AWS CLI is installed and configured with proper credentials"
    echo "  - The environment variable KEY_PAIR is set (e.g., export KEY_PAIR=my-key)"
    echo "  - The instance type 'm5.xlarge' must be supported in your account/region for Nitro Enclaves"
    echo ""
    echo "Usage:"
    echo "  export KEY_PAIR=<your-key-pair-name>"
    echo "  # optional: export REGION=<your-region>  (defaults to us-east-1)"
    echo "  # optional: export AMI_ID=<your-ami-id>  (defaults to ami-085ad6ae776d8f09c)"
    echo "  # optional: export API_ENV_VAR_NAME=<env-var-name> (defaults to 'API_KEY')"
    echo "  # optional: export INSTANCE_TYPE=<your-instance-type> (defaults to 'm5.xlarge')"
    echo "  # optional: export VPC_ID=<your-vpc-id> (uses default or creates new if missing)"
    echo "  ./configure_enclave.sh"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo ".env support: set KEY_PAIR, REGION, AMI_ID, API_ENV_VAR_NAME, EC2_INSTANCE_NAME, INSTANCE_TYPE, VPC_ID, USE_SECRET, SECRET_CHOICE, USER_SECRET_NAME, SECRET_VALUE in .env and they will be auto-loaded."
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

load_env_file



############################
# Configurable Defaults
############################
# Sets the region by default to us-east-1
REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

# The default AMI for us-east-1. Change this if your region is different.
AMI_ID="${AMI_ID:-ami-085ad6ae776d8f09c}"

INSTANCE_TYPE="${INSTANCE_TYPE:-m5.xlarge}"

# Environment variable name for our secret; default is 'API_KEY'
API_ENV_VAR_NAME="${API_ENV_VAR_NAME:-API_KEY}"

ALLOWLIST_PATH="src/nautilus-server/bun/allowed_endpoints.yaml"

############################
# Cleanup Old Files
############################
rm user-data.sh 2>/dev/null
rm trust-policy.json 2>/dev/null
rm secrets-policy.json 2>/dev/null

############################
# Check KEY_PAIR
############################
if [ -z "$KEY_PAIR" ]; then
    echo "Error: Environment variable KEY_PAIR is not set. Please export KEY_PAIR=<your-key-name>."
    exit 1
fi
# Check if yq is available
if ! command -v yq >/dev/null 2>&1; then
  echo "Error: yq is not installed."
  echo "Please install yq (for example: 'brew install yq' on macOS or 'sudo apt-get install yq' on Ubuntu) and try again."
  exit 1
fi

#echo "yq is installed. Proceeding..."

############################
# Set the EC2 Instance Name
############################
if [ -z "$EC2_INSTANCE_NAME" ]; then
    read -p "Enter EC2 instance base name: " EC2_INSTANCE_NAME
fi

if command -v shuf >/dev/null 2>&1; then
    RANDOM_SUFFIX=$(shuf -i 100000-999999 -n 1)
else
    RANDOM_SUFFIX=$(printf "%06d" $(( RANDOM % 900000 + 100000 )))
fi

FINAL_INSTANCE_NAME="${EC2_INSTANCE_NAME}-${RANDOM_SUFFIX}"
echo "Instance will be named: $FINAL_INSTANCE_NAME"


#########################################
# Read endpoints from allowed_endpoints.yaml
#########################################
if [ -f "$ALLOWLIST_PATH" ]; then
    # Use a small Python snippet to parse the YAML and emit space-separated endpoints
    ENDPOINTS=$(yq e '.endpoints | join(" ")' $ALLOWLIST_PATH 2>/dev/null)
    if [ -n "$ENDPOINTS" ]; then
        echo "Endpoints found in $ALLOWLIST_PATH (before region patching):"
        echo "$ENDPOINTS"

        # Replace any existing region (like us-east-1, us-west-2, etc.) in kms.* / secretsmanager.* with the user-provided $REGION.
        # This way, if $REGION=us-west-2, you'll get kms.us-west-2.amazonaws.com etc.
        ENDPOINTS=$(echo "$ENDPOINTS" \
          | sed "s|kms\.[^.]*\.amazonaws\.com|kms.$REGION.amazonaws.com|g" \
          | sed "s|secretsmanager\.[^.]*\.amazonaws\.com|secretsmanager.$REGION.amazonaws.com|g")
        echo "Endpoints after region patching:"
        echo "$ENDPOINTS"
    else
        echo "No endpoints found in $ALLOWLIST_PATH. Continuing without additional endpoints."
    fi
else
    echo "$ALLOWLIST_PATH not found. Continuing without additional endpoints."
    ENDPOINTS=""
fi

#########################################
# Decide about secrets (3 scenarios)
#########################################
if [ -z "$USE_SECRET" ]; then
    read -p "Do you want to use a secret? (y/n): " USE_SECRET
else
    echo "Using preset USE_SECRET value: $USE_SECRET"
fi

if [[ ! "$USE_SECRET" =~ ^[YyNn]$ ]]; then
    echo "Error: Please enter 'y' or 'n'"
    exit 1
fi

if [[ "$USE_SECRET" =~ ^[Yy]$ ]]; then
    if [ -z "$SECRET_CHOICE" ]; then
        read -p "Do you want to create a new secret or use an existing secret ARN? (new/existing): " SECRET_CHOICE
    else
        echo "Using preset SECRET_CHOICE value: $SECRET_CHOICE"
    fi

    if [[ ! "$SECRET_CHOICE" =~ ^([Nn]ew|NEW|[Ee]xisting|EXISTING)$ ]]; then
        echo "Error: Please enter 'new' or 'existing'"
        exit 1
    fi

    if [[ "$SECRET_CHOICE" =~ ^([Nn]ew|NEW)$ ]]; then
        if [ -z "$USER_SECRET_NAME" ]; then
            read -p "Enter secret name: " USER_SECRET_NAME
        else
            echo "Using preset USER_SECRET_NAME value: $USER_SECRET_NAME"
        fi
    fi
fi

# Re-check USE_SECRET after potential seal detection
if [[ "$USE_SECRET" =~ ^[Yy]$ ]]; then
    if [[ "$SECRET_CHOICE" =~ ^([Nn]ew|NEW)$ ]]; then
        if [ -z "$SECRET_VALUE" ]; then
            read -s -p "Enter secret value: " SECRET_VALUE
            echo ""
        else
            echo "Using preset SECRET_VALUE (hidden)"
        fi
        SECRET_NAME="${USER_SECRET_NAME}"
        echo "Creating secret '$SECRET_NAME' in AWS Secrets Manager..."
        CREATE_OUTPUT=$(aws secretsmanager create-secret \
          --name "$SECRET_NAME" \
          --secret-string "$SECRET_VALUE" \
          --region "$REGION" \
          --query 'ARN' --output text 2>&1)
        CREATE_RC=$?
        if [ $CREATE_RC -ne 0 ] || [ -z "$CREATE_OUTPUT" ] || [ "$CREATE_OUTPUT" = "None" ]; then
            echo "Create failed, checking existing secret by name..."
            EXISTING_ARN=$(aws secretsmanager list-secrets --region "$REGION" \
              --query "SecretList[?Name=='$USER_SECRET_NAME'].ARN | [0]" --output text)
            if [ -n "$EXISTING_ARN" ] && [ "$EXISTING_ARN" != "None" ]; then
                echo "Deleting existing secret $USER_SECRET_NAME ($EXISTING_ARN)..."
                aws secretsmanager delete-secret --secret-id "$EXISTING_ARN" --force-delete-without-recovery --region "$REGION"
                for i in {1..10}; do
                    CHECK=$(aws secretsmanager list-secrets --region "$REGION" \
                      --query "SecretList[?Name=='$USER_SECRET_NAME'].ARN | [0]" --output text)
                    if [ -z "$CHECK" ] || [ "$CHECK" = "None" ]; then
                        break
                    fi
                    sleep 2
                done
                echo "Re-creating secret '$SECRET_NAME'..."
                SECRET_ARN=$(aws secretsmanager create-secret \
                  --name "$SECRET_NAME" \
                  --secret-string "$SECRET_VALUE" \
                  --region "$REGION" \
                  --query 'ARN' --output text)
                if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
                    echo "Failed to re-create secret. Please ensure credentials and permissions."
                    exit 1
                fi
                echo "Secret created with ARN: $SECRET_ARN"
            else
                echo "Secret not found by name; please check AWS permissions or region."
                read -p "Secret ARN: " SECRET_ARN
            fi
        else
            SECRET_ARN="$CREATE_OUTPUT"
            echo "Secret created with ARN: $SECRET_ARN"
        fi

        # Create IAM Role, Policy, and Instance Profile for Secret Access
        ROLE_NAME="role-${FINAL_INSTANCE_NAME}"
        echo "Creating IAM role '$ROLE_NAME' for the EC2 instance..."

        cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

        aws iam create-role \
           --role-name "$ROLE_NAME" \
           --assume-role-policy-document file://trust-policy.json > /dev/null 2>&1

        cat <<EOF > secrets-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "$SECRET_ARN"
    }
  ]
}
EOF

        aws iam put-role-policy \
           --role-name "$ROLE_NAME" \
           --policy-name "$FINAL_INSTANCE_NAME" \
           --policy-document file://secrets-policy.json > /dev/null 2>&1

        aws iam create-instance-profile \
           --instance-profile-name "$ROLE_NAME" > /dev/null 2>&1

        aws iam add-role-to-instance-profile \
           --instance-profile-name "$ROLE_NAME" \
           --role-name "$ROLE_NAME" > /dev/null 2>&1

        IAM_INSTANCE_PROFILE_OPTION=""

        # Remove old references first and add new secret fetching logic
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
            sed -i '' '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
            
            sed -i '' "/# Secrets-block/a\\
SECRET_VALUE=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_ARN} --region ${REGION} | jq -r .SecretString)\\
echo \"\$SECRET_VALUE\" | jq -R '{\"${API_ENV_VAR_NAME}\": .}' > secrets.json\\
" expose_enclave.sh
        else
            sed -i '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
            sed -i '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
            
            sed -i "/# Secrets-block/a\\
SECRET_VALUE=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_ARN} --region ${REGION} | jq -r .SecretString)\\
echo \"\$SECRET_VALUE\" | jq -R '{\"${API_ENV_VAR_NAME}\": .}' > secrets.json" expose_enclave.sh
        fi

        echo "Secret fetching logic added to expose_enclave.sh"

    elif [[ "$SECRET_CHOICE" =~ ^([Ee]xisting|EXISTING)$ ]]; then
        #----------------------------------------------------
        # Use an existing secret ARN
        #----------------------------------------------------
        read -p "Enter the existing secret ARN: " SECRET_ARN

        # Validate that the secret exists and has a value
        echo "Validating secret ARN..."
        SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" 2>&1)
        if [ $? -ne 0 ]; then
            echo "Error: Failed to retrieve secret. Enter a valid secret ARN and try again. "
            echo "AWS CLI error:"
            echo "$SECRET_VALUE"
            exit 1
        fi
        
        # Extract the actual secret value from the JSON response
        SECRET_VALUE=$(echo "$SECRET_VALUE" | jq -r '.SecretString // empty')
        if [ -z "$SECRET_VALUE" ]; then
            echo "Error: Invalid secret string."
            exit 1
        fi
        echo "Secret validation successful"

        # We won't create a new secret, but we still need the instance role if we need
        # to actually read from Secrets Manager.
        ROLE_NAME="role-${FINAL_INSTANCE_NAME}"
        echo "Creating IAM role '$ROLE_NAME' for the EC2 instance..."

        cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

          aws iam create-role \
             --role-name "$ROLE_NAME" \
             --assume-role-policy-document file://trust-policy.json > /dev/null 2>&1

          cat <<EOF > secrets-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "$SECRET_ARN"
    }
  ]
}
EOF

          aws iam put-role-policy \
             --role-name "$ROLE_NAME" \
             --policy-name "$FINAL_INSTANCE_NAME" \
             --policy-document file://secrets-policy.json > /dev/null 2>&1

          aws iam create-instance-profile \
             --instance-profile-name "$ROLE_NAME" > /dev/null 2>&1

          aws iam add-role-to-instance-profile \
             --instance-profile-name "$ROLE_NAME" \
             --role-name "$ROLE_NAME" > /dev/null 2>&1

          IAM_INSTANCE_PROFILE_OPTION=""
        
        # Remove old references first
        if [[ "$(uname)" == "Darwin" ]]; then
          sed -i '' '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
          sed -i '' '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
        else
          sed -i '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
          sed -i '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
        fi

        echo "Inserting existing secret ARN lines into expose_enclave.sh..."

        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/# Secrets-block/a\\
SECRET_VALUE=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_ARN} --region ${REGION} | jq -r .SecretString)\\
echo \"\$SECRET_VALUE\" | jq -R '{\"${API_ENV_VAR_NAME}\": .}' > secrets.json" expose_enclave.sh
        else
            sed -i "/# Secrets-block/a\\
SECRET_VALUE=\$(aws secretsmanager get-secret-value --secret-id ${SECRET_ARN} --region ${REGION} | jq -r .SecretString)\\
echo \"\$SECRET_VALUE\" | jq -R '{\"${API_ENV_VAR_NAME}\": .}' > secrets.json" expose_enclave.sh
        fi

    else
        echo "Invalid choice. No secret created or used."
        IAM_INSTANCE_PROFILE_OPTION=""
        ROLE_NAME=""

        # Remove references
        if [[ "$(uname)" == "Darwin" ]]; then
          sed -i '' '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
          sed -i '' '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
        else
          sed -i '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
          sed -i '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
        fi
    fi

else
    #-----------------------------------------
    # No secret configuration
    #-----------------------------------------
    echo "Configuring without AWS secrets..."
    
    # Clear IAM-related variables
    IAM_INSTANCE_PROFILE_OPTION=""
    ROLE_NAME=""

    # Remove any existing secret references from expose_enclave.sh
    echo "Removing secret references from expose_enclave.sh..."
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
        sed -i '' '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
    else
        sed -i '/SECRET_VALUE=/d' expose_enclave.sh 2>/dev/null || true
        sed -i '/echo.*secrets\.json/d' expose_enclave.sh 2>/dev/null || true
    fi
    
    # Regular no-secret configuration
    echo "Standard no-secret configuration applied."
    
    # Add empty secrets.json for compatibility with run.sh
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "/# Secrets-block/a\\
# No secrets: create empty secrets.json for compatibility\\
echo '{}' > secrets.json\\
" expose_enclave.sh
    else
        sed -i "/# Secrets-block/a\\
# No secrets: create empty secrets.json for compatibility\\
echo '{}' > secrets.json" expose_enclave.sh
    fi
fi


#############################################################
# Create the user-data script that the instance will run
# on first boot.
#############################################################
cat <<'EOF' > user-data.sh
#!/bin/bash
# Update the instance and install Nitro Enclaves tools, Docker and other utilities
sudo yum update -y
sudo yum install -y aws-nitro-enclaves-cli-devel aws-nitro-enclaves-cli docker nano socat git make

# Add the current user to the docker group (so you can run docker without sudo)
sudo usermod -aG docker ec2-user

# Start and enable Nitro Enclaves allocator and Docker services
sudo systemctl start nitro-enclaves-allocator.service && sudo systemctl enable nitro-enclaves-allocator.service
sudo systemctl start docker && sudo systemctl enable docker
sudo systemctl enable nitro-enclaves-vsock-proxy.service
EOF



# Append endpoint configuration to the vsock-proxy YAML if endpoints were provided.
if [ -n "$ENDPOINTS" ]; then
    for ep in $ENDPOINTS; do
        echo "echo \"- {address: $ep, port: 443}\" | sudo tee -a /etc/nitro_enclaves/vsock-proxy.yaml" >> user-data.sh
    done
fi

# Continue the user-data script
cat <<'EOF' >> user-data.sh
# Stop the allocator so we can modify its configuration
sudo systemctl stop nitro-enclaves-allocator.service

# Adjust the enclave allocator memory (default set to 3072 MiB)
ALLOCATOR_YAML=/etc/nitro_enclaves/allocator.yaml
MEM_KEY=memory_mib
DEFAULT_MEM=3072
sudo sed -r "s/^(\s*${MEM_KEY}\s*:\s*).*/\1${DEFAULT_MEM}/" -i "${ALLOCATOR_YAML}"

# Restart the allocator with the updated memory configuration
sudo systemctl start nitro-enclaves-allocator.service && sudo systemctl enable nitro-enclaves-allocator.service

# Restart vsock-proxy processes for various endpoints.
EOF

# Append additional vsock-proxy commands for each extra endpoint.
if [ -n "$ENDPOINTS" ]; then
    PORT=8101
    for ep in $ENDPOINTS; do
        echo "vsock-proxy $PORT $ep 443 --config /etc/nitro_enclaves/vsock-proxy.yaml &" >> user-data.sh
        PORT=$((PORT+1))
    done
fi

###################################################################
# Fix src/nautilus-server/run.sh to add endpoint + forwarders
###################################################################
ip=64
endpoints_config=""
for ep in $ENDPOINTS; do
    endpoints_config="${endpoints_config}echo \"127.0.0.${ip}   ${ep}\" >> /etc/hosts"$'\n'
    ip=$((ip+1))
done

echo "Adding the following endpoint configuration to src/nautilus-server/run.sh:"
echo "$endpoints_config"

# Remove any existing endpoint lines (except the first localhost line)
if [[ "$(uname)" == "Darwin" ]]; then
    # Remove only the IP mapping lines, preserving comments
    sed -i '' '/echo "127.0.0.[0-9]*   .*" >> \/etc\/hosts/d' src/nautilus-server/run.sh
    # Restore the localhost line if it was removed
    if ! grep -q "echo \"127.0.0.1   localhost\" > /etc/hosts" src/nautilus-server/run.sh; then
        sed -i '' '/# Add a hosts record/a\
echo "127.0.0.1   localhost" > /etc/hosts' src/nautilus-server/run.sh
    fi
else
    # Remove only the IP mapping lines, preserving comments
    sed -i '/echo "127.0.0.[0-9]*   .*" >> \/etc\/hosts/d' src/nautilus-server/run.sh
    # Restore the localhost line if it was removed
    if ! grep -q "echo \"127.0.0.1   localhost\" > /etc/hosts" src/nautilus-server/run.sh; then
        sed -i '/# Add a hosts record/a\echo "127.0.0.1   localhost" > /etc/hosts' src/nautilus-server/run.sh
    fi
fi

# Add the new endpoint configuration
tmp_hosts="/tmp/endpoints_config.txt"
echo "$endpoints_config" > "$tmp_hosts"

# Insert after the localhost line
if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "/echo \"127.0.0.1   localhost\" > \/etc\/hosts/ r $tmp_hosts" src/nautilus-server/run.sh
else
    sed -i "/echo \"127.0.0.1   localhost\" > \/etc\/hosts/ r $tmp_hosts" src/nautilus-server/run.sh
fi
rm "$tmp_hosts"

ip_forwarder=64
port_forwarder=8101
traffic_config=""
for ep in $ENDPOINTS; do
    traffic_config="${traffic_config}python3 /traffic_forwarder.py 127.0.0.${ip_forwarder} 443 3 ${port_forwarder} &"$'\n'
    ip_forwarder=$((ip_forwarder+1))
    port_forwarder=$((port_forwarder+1))
done

echo "Adding the following traffic forwarder configuration to src/nautilus-server/run.sh:"
echo "$traffic_config"

# Remove any existing traffic forwarder lines
if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' '/python3 \/traffic_forwarder.py/d' src/nautilus-server/run.sh
else
    sed -i '/python3 \/traffic_forwarder.py/d' src/nautilus-server/run.sh
fi

# Add the new traffic forwarder configuration
tmp_traffic="/tmp/traffic_config.txt"
echo "$traffic_config" > "$tmp_traffic"

if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "/# Traffic-forwarder-block/ r $tmp_traffic" src/nautilus-server/run.sh
else
    sed -i "/# Traffic-forwarder-block/ r $tmp_traffic" src/nautilus-server/run.sh
fi
rm "$tmp_traffic"

echo "updated run.sh"

# Configure VPC and subnet
setup_vpc_subnet() {
  if [ -n "$VPC_ID" ]; then
    VPC_CHECK=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" 2>&1)
    if [ $? -ne 0 ]; then
      echo "Error: Specified VPC does not exist or is not accessible."
      echo "$VPC_CHECK"
      exit 1
    fi
  else
    DEFAULT_VPC=$(aws ec2 describe-vpcs --filter "Name=isDefault,Values=true" --region "$REGION" --query "Vpcs[0].VpcId" --output text)
    if [ "$DEFAULT_VPC" != "None" ] && [ -n "$DEFAULT_VPC" ]; then
      VPC_ID=$DEFAULT_VPC
    else
      VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region "$REGION" --query "Vpc.VpcId" --output text)
      aws ec2 wait vpc-available --vpc-ids "$VPC_ID" --region "$REGION"
      IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" --query "InternetGateway.InternetGatewayId" --output text)
      aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$REGION"
    fi
  fi
  SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region "$REGION" --query "Subnets[0].SubnetId" --output text)
  if [ "$SUBNET_ID" = "None" ] || [ -z "$SUBNET_ID" ]; then
    AZ=$(aws ec2 describe-availability-zones --region "$REGION" --query "AvailabilityZones[0].ZoneName" --output text)
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 --availability-zone "$AZ" --region "$REGION" --query "Subnet.SubnetId" --output text)
    aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region "$REGION"
    ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION"
    aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$ROUTE_TABLE_ID" --region "$REGION"
  fi
}

setup_vpc_subnet



############################
# Create or Use Security Group
############################
SECURITY_GROUP_NAME="instance-script-sg"

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null)

if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  echo "Creating security group $SECURITY_GROUP_NAME..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SECURITY_GROUP_NAME" \
    --vpc-id "$VPC_ID" \
    --description "Security group allowing SSH (22), HTTPS (443), and port 3000" \
    --query "GroupId" --output text)

  # Ensure that the security group is created successfully
  if [ $? -ne 0 ]; then
    echo "Error creating security group."
    exit 1
  fi

  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0

  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0

  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 3000 --cidr 0.0.0.0/0
else
  echo "Using existing security group $SECURITY_GROUP_NAME ($SECURITY_GROUP_ID)"
fi

############################
# Launch EC2 or use existing instance
############################

if [ -n "$INSTANCE_ID" ]; then
  INSTANCE_CHECK=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>&1)
  if [ $? -ne 0 ]; then
    echo "Error: Specified instance does not exist or is not accessible."
    echo "$INSTANCE_CHECK"
    exit 1
  fi
  ENCLAVE_SUPPORT=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].EnclaveOptions.Enabled" --output text)
  if [ "$ENCLAVE_SUPPORT" != "True" ] && [ "$ENCLAVE_SUPPORT" != "true" ]; then
    read -p "The specified instance may not have Nitro Enclaves enabled. Continue? (y/n): " CONTINUE_WITH_INSTANCE
    if [[ ! "$CONTINUE_WITH_INSTANCE" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
  INSTANCE_NAME=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].Tags[?Key=='Name'].Value" --output text)
  if [ -z "$INSTANCE_NAME" ]; then
    INSTANCE_NAME="$FINAL_INSTANCE_NAME"
    aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=$INSTANCE_NAME" "Key=instance-script,Value=true" --region "$REGION"
  fi
  PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  cat user-data.sh > setup_existing_instance.sh
  chmod +x setup_existing_instance.sh
else
  echo "Launching EC2 instance with Nitro Enclaves enabled..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR" \
    --user-data file://user-data.sh \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200}}]' \
    --enclave-options Enabled=true \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${FINAL_INSTANCE_NAME}},{Key=instance-script,Value=true}]" \
    --query "Instances[0].InstanceId" --output text)
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
fi

# If an IAM role was created, associate its instance profile with the instance.
if [ -n "$ROLE_NAME" ]; then
    echo "Associating IAM instance profile $ROLE_NAME with instance $INSTANCE_ID"
    aws ec2 associate-iam-instance-profile \
        --instance-id "$INSTANCE_ID" \
        --iam-instance-profile Name="$ROLE_NAME" \
        --region "$REGION" > /dev/null 2>&1
fi

sleep 10

# Updates the ROLE_NAME in expose_enclave.sh to current role name
if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s/^ROLE_NAME=\".*\"/ROLE_NAME=\"$ROLE_NAME\"/" expose_enclave.sh
else
  sed -i "s/^ROLE_NAME=\".*\"/ROLE_NAME=\"$ROLE_NAME\"/" expose_enclave.sh
fi

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[].Instances[].PublicIpAddress" \
  --output text)

echo "[*] Commit the code generated in expose_enclave.sh and src/nautilus-server/run.sh. They will be needed when building the enclave inside the instance."
echo "[*] Please wait 2-3 minutes for the instance to finish the init script before sshing into it."
echo "[*] ssh inside the launched EC2 instance. e.g. \`ssh ec2-user@\"$PUBLIC_IP\"\` assuming the ssh-key is loaded into the agent."
echo "[*] Clone or copy the repo with the above generated code."
echo "[*] Inside repo directory: 'make run'"
echo "[*] Run expose_enclave.sh from within the EC2 instance to expose the enclave to the internet."

echo
echo "==== Next Steps (auto-generated) ===="
echo "Public IP: $PUBLIC_IP"
echo "Sync code:"
echo "  rsync -av --exclude-from=.scpignore --delete --delete-excluded -e \"ssh -i ~/.ssh/${KEY_PAIR}.pem\" ./ ec2-user@$PUBLIC_IP:~/nautilus/"
echo "On EC2:"
echo "  ssh -i ~/.ssh/${KEY_PAIR}.pem ec2-user@$PUBLIC_IP"
echo "  cd ~/nautilus && make stop && make && make run && sh expose_enclave.sh"
echo "Verify:"
echo "  curl -H 'Content-Type: application/json' -X GET http://$PUBLIC_IP:3000/health_check"
echo "  curl -H 'Content-Type: application/json' -X GET http://$PUBLIC_IP:3000/get_attestation"

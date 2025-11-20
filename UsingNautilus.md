## Table of Contents:

- [Introduction](README.md)
- [Nautilus Design](Design.md)
- [LICENSE](LICENSE)

# Using Nautilus

The Nautilus framework helps you deploy an AWS Nitro Enclave with all the necessary scaffolding, such as reproducible builds, signature formatting, and HTTPS traffic forwarding, so you can focus on implementing the offchain computation logic inside the enclave.

In addition, the framework provides an onchain template that includes the minimal smart contract code required to register a Nautilus instance and its public key. As a Dapp developer, using Nautilus is as simple as:

1. Implement the enclave in Typescript (Bun + Elysia) with the desired computation logic.
2. Deploy a Move smart contract that stores the expected PCRs and allows updates by the contract deployer.
3. Deploy the enclave instance on AWS and register it onchain using its attestation document.
4. Upload signed responses from the registered enclave, verify them onchain, and consume the results in your smart contract.

This guide walks you through the following steps:

1. Writing and deploying a simple Nautilus offchain instance using AWS Nitro Enclaves. The example instance runs a server that verifies Twitter profiles.
2. Writing a Move smart contract that registers the enclave by verifying its attestation and public key, then verifies the Nautilus response (signature and payload) onchain.

The setup script performs the following actions:

- Launches a preconfigured EC2 instance and allocates a Nitro Enclave.
- Builds the Rust-based template application into an Enclave Image Format (EIF) binary and runs it inside the enclave.
- Configures required HTTP domains so the enclave can access external APIs via the parent EC2 instance (since the enclave itself has no internet access).
- Exposes two endpoints to allow client-side communication with the enclave.

When the enclave starts, it generates a fresh enclave key pair and exposes the following two endpoints:

- `health_check`: Probes all allowed domains inside the enclave.
- `get_attestation`: Returns a signed attestation document over the enclave public key. Use this during onchain registration.
- `process_data`: The main application logic. In this template, it verifies a Twitter profile and signs the result. This logic is customizable in `elysia_server.ts`.

## Code structure

```shell
/move
  /enclave          Utility functions for generating enclave config and registering the public key with an attestation document.
  /twitter-example  Entry point for onchain logic as an example, which uses enclave functions to run your Nautilus application logic. 
/src
  /nautilus-server  Nautilus server that runs inside the enclave.
    /bun
      elysia_server.ts        The main server entry point. Modify this file to implement your application logic.
      allowed_endpoints.yaml  List of allowed external endpoints.
      package.json            Dependencies and scripts.
      /common                 Nautilus infrastructure code (attestation, signing, etc.). Do not modify.
    run.sh          Runs the server inside the enclave. Do not modify.
```

* Modify `src/nautilus-server/bun/elysia_server.ts` to implement your offchain logic.
* Update `src/nautilus-server/bun/allowed_endpoints.yaml` with any external APIs you need.
* Add a new directory under `move/` for your Move contract if needed, or modify the existing `twitter-example`.

> [!Note]
> Frontend code is not included in this guide. The Move call is demonstrated using the CLI.

## Run the example enclave

1. Set up an AWS developer account and install the AWS CLI. For detailed instructions, see the [AWS Nitro Enclaves getting started guide](https://docs.aws.amazon.com/enclaves/latest/user/getting-started.html#launch-instance).

2. Run the script below and follow the prompts. It will ask you to enter some values - see the next step if you want to run this example as-is. If the script completes successfully, it will generate code locally that you’ll need to commit. If you encounter issues, refer to the note below, as instructions may vary depending on your AWS account settings.

```shell
export KEY_PAIR=<your-key-pair-name>
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>
export AWS_SESSION_TOKEN=<your-session-token>

sh configure_enclave.sh
```

> [!NOTE]
> - Run `sh configure_enclave.sh -h` to view additional instructions.
> - If your AWS account is not in `us-east-1`, you may need to configure `REGION` and `AMI_ID` values specific to your region. Refer to this [guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/finding-an-ami.html) to find a suitable Amazon Linux image ID. 
> ```
> export REGION=<your-region>
> export AMI_ID=<find-an-amazon-linux-ami-for-your-region>
> ```
> - To find the values for `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`, refer to this [guide](https://docs.aws.amazon.com/streams/latest/dev/setting-up.html).
> - Set `KEY_PAIR` to the name of your existing AWS key pair or one you create. To create a key pair, refer to this [guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
> - You may need to create a vpc with a public subnet. Refer to this [guide](https://000058.awsstudygroup.com/2-prerequiste/2.1-createec2/2.1.2-createpublicsubnet/) for instructions.

3. The script will prompt you for configuration. For the Twitter example, if you choose to use a secret, it refers to the API Bearer Token associated with your Twitter Developer account.
```shell
Enter EC2 instance base name: twitter-verifier
Do you want to use a secret? (y/n): y
...
``` 

4. If completed successfully, changes will be generated in `/src/nautilus-server/run.sh` and `expose_enclave.sh`. Commit these changes, as they are required when building the enclave image.

> [!NOTE]
> - To allow the enclave to access additional external domains, add them to `allowed_endpoints.yaml`. If you update this file, you must re-run `configure_enclave.sh` to generate a new instance, as the endpoint list is compiled into the enclave build.
> - You can optionally create a secret to store any sensitive value you don’t want included in the codebase. The secret is passed to the enclave as an environment variable. You can verify newly created secrets or find existing ARNs in the [AWS Secrets Manager console](https://us-east-1.console.aws.amazon.com/secretsmanager/listsecrets?region=<REGION>).

5. Connect to your instance and clone the repository. For detailed instructions, see [Connect to your Linux instance using SSH](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-linux-inst-ssh.html#connect-linux-inst-sshClient) in the AWS documentation.

6. You should now be inside the directory containing the server code, including the committed file changes from the previous step. Next, build the enclave image, run it, and expose the HTTP endpoint on port 3000. 

```shell
cd nautilus/
make run
sh expose_enclave.sh
```

> [!NOTE]
> Use `make run-debug` instead of `make run` to run the enclave in debug mode. This will print all logs, which the production build does not. Note that in debug mode, the PCR values will be all zeros and are not valid for production use.

7. Congratulations! You can now interact with the enclave from the outside world. You can find the `PUBLIC_IP` in the AWS console.

```shell
curl -H 'Content-Type: application/json' -X GET http://<PUBLIC_IP>:3000/health_check

curl -H 'Content-Type: application/json' -X GET http://<PUBLIC_IP>:3000/get_attestation

curl -H 'Content-Type: application/json' -d '{"payload": { "user_url": "https://x.com/Mysten_Labs/status/1234567890"}}' -X POST http://<PUBLIC_IP>:3000/process_data
```

8. Optionally, you can set up an Application Load Balancer (ALB) for the EC2 instance with an SSL/TLS certificate from AWS Certificate Manager (ACM), and configure Amazon Route 53 for DNS routing. For more information, see the [AWS Certificate Manager User Guide](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html) and the [Application Load Balancer Guide](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html).

## Develop your own Nautilus server

The Nautilus server logic lives in `src/nautilus-server/bun`.
- `elysia_server.ts`: The main application logic. Modify this file to implement your specific requirements.
- `allowed_endpoints.yaml`: Specify any external domains your application needs to access.

You can test the server locally using Bun:

To test the `process_data` endpoint locally, run the following:

```shell
cd src/nautilus-server/bun
bun install
API_KEY=your_key bun run elysia_server.ts

# In another terminal
curl -H 'Content-Type: application/json' -d '{"payload": { "user_url": "..."}}' -X POST http://localhost:3000/process_data
```

### Troubleshooting

- Traffic forwarder error: Ensure all targeted domains are listed in the `allowed_endpoints.yaml`. The following command can be used to test enclave connectivities to all domains.

```shell
curl -H 'Content-Type: application/json' -X GET http://<PUBLIC_IP>:3000/health_check

{"pk":"f343dae1df7f2c4676612368e40bf42878e522349e4135c2caa52bc79f0fc6e2","endpoints_status":{"api.weatherapi.com":true}}
```

- Docker is not running: The EC2 instance may still be starting up. Wait a few moments, then try again.

- Cannot connect to enclave: This may be due to a VSOCK communication issue. Verify that the enclave is running and properly exposed with `sh expose_enclave.sh`.

### Reset

```shell
cd nautilus/
sh reset_enclave.sh
```
Then repeat step 6.

## Build locally to check reproducibility

Every enclave built from the same source code (everything in `/src`) can produce identical PCRs through reproducible builds.
Note that this includes any traffic forwarding changes made in `run.sh` (see branch `example-configuration`).

```shell
cd nautilus/
make

cat out/nitro.pcrs

# add env var that will be used later when registering the enclave.
PCR0=14245f411c034ca453c7afcc666007919ca618da943e5a78823819e9bcee2084c4d9f582a3d4c99beb80ad1c3ea290f7
PCR1=14245f411c034ca453c7afcc666007919ca618da943e5a78823819e9bcee2084c4d9f582a3d4c99beb80ad1c3ea290f7
PCR2=21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a
```

## Register the enclave onchain

After finalizing the Rust code, the Dapp administrator can register the enclave with the corresponding PCRs and public key.

```shell
# optionally
sui client switch --env testnet # or appropriate network
sui client gas # request gas from faucet.sui.io if needed

# deploy the enclave package
cd move/enclave
sui move build
sui client publish

# record ENCLAVE_PACKAGE_ID as env var from publish output
ENCLAVE_PACKAGE_ID=0x3b009f952e11f0fa0612d0a8e07461fb69edc355d732e5d6e39267b1b4fd7138

# deploy your dapp logic
cd ../twitter-example
sui move build
sui client publish

# record CAP_OBJECT_ID (owned object of type Cap), ENCLAVE_CONFIG_OBJECT_ID (shared object), APP_PACKAGE_ID (package containing twitter module) as env var from publish output

CAP_OBJECT_ID=0xb232d20245ba2d624d1c1628c4fc062bd1d3249601385476d9736fc60c897d2b
ENCLAVE_CONFIG_OBJECT_ID=0x9a50017ab37090ef4b5704eb24201c88b2e4bbad2aad1d4e69ecf1bdfbae9ccb
APP_PACKAGE_ID=0x097b551dec72f0c47e32e5f8114d0d12a98ab31762d21adff295f6d95d353154

# record the deployed enclave url, e.g. http://<PUBLIC_IP>:3000
ENCLAVE_URL=<DEPLOYED_URL>

# the module name and otw name used to create the dapp, defined in your Move code `fun init`
MODULE_NAME=twitter
OTW_NAME=TWITTER

# make sure all env vars are populated
echo $APP_PACKAGE_ID
echo $ENCLAVE_PACKAGE_ID
echo $CAP_OBJECT_ID
echo $ENCLAVE_CONFIG_OBJECT_ID
echo 0x$PCR0
echo 0x$PCR1
echo 0x$PCR2
echo $MODULE_NAME
echo $OTW_NAME
echo $ENCLAVE_URL

# =======
# the two steps below (update pcrs, register enclave) can be reused if enclave server is updated
# =======

# this calls the update_pcrs onchain with the enclave cap and built PCRs, this can be reused to update PCRs if Rust server code is updated
sui client call --function update_pcrs --module enclave --package $ENCLAVE_PACKAGE_ID --type-args "$APP_PACKAGE_ID::$MODULE_NAME::$OTW_NAME" --args $ENCLAVE_CONFIG_OBJECT_ID $CAP_OBJECT_ID 0x$PCR0 0x$PCR1 0x$PCR2

# optional, give it a name you like
sui client call --function update_name --module enclave --package $ENCLAVE_PACKAGE_ID --type-args "$APP_PACKAGE_ID::$MODULE_NAME::$OTW_NAME" --args $ENCLAVE_CONFIG_OBJECT_ID $CAP_OBJECT_ID "twitter enclave, updated 2025-05-13"

# this script calls the get_attestation endpoint from your enclave url and use it to calls register_enclave onchain to register the public key, results in the created enclave object
sh ../../register_enclave.sh $ENCLAVE_PACKAGE_ID $APP_PACKAGE_ID $ENCLAVE_CONFIG_OBJECT_ID $ENCLAVE_URL $MODULE_NAME $OTW_NAME

# record the created shared object ENCLAVE_OBJECT_ID as env var from register output
ENCLAVE_OBJECT_ID=0x1c9ccfc0f391f5e679e1f9f7d53c7fa455bf977e0f6dc71222990401f359c42a
```

You can view an [example enclave config object](https://testnet.suivision.xyz/object/0x58a6a284aaea8c8e71151e4ae0de2350ae877f0bd94adc2b2d0266cf23b6b41d) containing PCR values on SuiScan. Additionally see an [example enclave object](https://testnet.suivision.xyz/object/0xe0e70df5347560a1b43e5954267cadd1386a562095cb4285f2581bf2974c838d) that includes the enclave’s registered public key.



You can view an [example enclave config object](https://testnet.suivision.xyz/object/0xe33641a2dae5eb4acad3859e603ec4e25641af05f837c85058645c7d8d9d831a) containing PCR values. You can also view an [example enclave object](https://testnet.suivision.xyz/object/0x53db077721140910697668f9b2ee80fbecd104ac076d60fc1fb49ae57cd96c0d) that includes the registered enclave public key.

You can find the frontend code for the Twitter example [in this repository](https://github.com/MystenLabs/nautilus-twitter/tree/main/frontend). 

### Enclave management

The template allows the admin to register multiple `Enclave` objects associated with one `EnclaveConfig` that defines PCRs. Each Enclave object represents a specific enclave instance with a unique public key, while the `EnclaveConfig` tracks the PCR values and their associated version. All new Enclave instances can be registered with the latest `config_version` to ensure consistency. 

This design allows the admin to run multiple instances of the same enclave with different public keys, where `config_version` is set to the latest version when creating an `Enclave` object. The admin can register or destroy their `Enclave` objects. 

### Update PCRs

The deployer of the smart contract holds the `EnclaveCap`, which allows for updating the PCRs and enclave public key if the Nautilus server code has been modified. You can retrieve the new PCRs using `make && cat out/nitro.pcrs`. To update the PCRs or register the enclave again, reuse the steps outlined in the section above.

## Using the verified computation in Move

For the Twitter example, you can request the enclave to verify a tweet:

```shell
curl -H 'Content-Type: application/json' -d '{"payload": { "user_url": "https://x.com/Mysten_Labs/status/1234567890"}}' -X POST http://<PUBLIC_IP>:3000/process_data
```

### Signing payload

Signing payloads in Move are constructed using BCS (Binary Canonical Serialization). These must match the structure specified in the enclave’s Rust code when generating the signature; otherwise, signature verification in `enclave.move` may fail.

It’s recommended to write unit tests in both Move and Typescript to ensure consistency.

## FAQs

1. There are many TEE providers available. Why did we choose AWS Nitro Enclaves initially?

We chose to initially support AWS Nitro Enclaves due to their maturity and support for reproducible builds. Support for additional TEE providers may be considered in the future.

2. Where is the root of trust of AWS?

It is stored as part of the Sui framework and used to verify AWS attestation documents. You can verify its hash by following the steps outlined [here](https://docs.aws.amazon.com/enclaves/latest/user/verify-root.html#validation-process).

```shell
curl https://raw.githubusercontent.com/MystenLabs/sui/refs/heads/main/crates/sui-types/src/nitro_root_certificate.pem -o cert_sui.pem
sha256sum cert_sui.pem

6eb9688305e4bbca67f44b59c29a0661ae930f09b5945b5d1d9ae01125c8d6c0

curl https://aws-nitro-enclaves.amazonaws.com/AWS_NitroEnclaves_Root-G1.zip -o cert_aws.zip
unzip cert_aws.zip
sha256sum root.pem

6eb9688305e4bbca67f44b59c29a0661ae930f09b5945b5d1d9ae01125c8d6c0 # check it matches from the one downloaded from the Sui repo
```

[Back to table of contents](#table-of-contents)

## AWS Nitro Enclaves Deployment

This section integrates the AWS Nitro Enclaves deployment guide and provides a streamlined path to run the enclave on AWS EC2 with Nitro Enclaves, exposing `3000` and `9184` ports and enabling attestation and metrics.

### Overview
- Goal: Deploy the Nautilus template on AWS EC2 + Nitro Enclaves and expose `3000`/`9184`.
- Endpoints: `health_check`, `get_attestation`, `process_data` available; metrics on `9184`.
- Reproducibility: PCRs reproducible via `out/nitro.pcrs`.

### Prerequisites
- macOS: `brew install awscli jq yq`
- Linux: `sudo apt-get/dnf install -y awscli jq yq`
- AWS CLI: `aws configure` (or set `AWS_PROFILE`, and include `AWS_SESSION_TOKEN` if using temporary credentials)
- SSH key: ensure `.pem` permissions `chmod 600 ~/.ssh/<your>.pem`

### AWS Region and AMI
- Default `REGION=us-east-1`
- Default `AMI_ID=ami-085ad6ae776d8f09c` (Amazon Linux 2023)
- Key Pair name: `aws ec2 describe-key-pairs --region <REGION>` → `export KEY_PAIR=<your-keypair>`
- Public IP: `aws ec2 describe-instances --region <REGION> --query "Reservations[*].Instances[*].[PublicIpAddress]" --output table`

### Configure locally
```sh
cd <Template Root Path>
export KEY_PAIR=<your-keypair>
export REGION=us-east-1
# optional: export AMI_ID=ami-085ad6ae776d8f09c
sh configure_enclave.sh
```
- The script will:
  - Reuse/create VPC, subnet, security group
  - Generate and update `expose_enclave.sh` and `src/nautilus-server/run.sh`
  - Enable `vsock-proxy` on the parent EC2 instance
  - Output `InstanceId` and `PUBLIC_IP`
- Commit generated files:
```sh
git add expose_enclave.sh src/nautilus-server/run.sh && git commit -m "Configure enclave"
```

### Build and run on EC2
```sh
rsync -av --exclude-from=.scpignore --delete --delete-excluded -e "ssh -i ~/.ssh/<your>.pem" ./ ec2-user@<PUBLIC_IP>:~/nautilus/
ssh -i ~/.ssh/<your>.pem ec2-user@<PUBLIC_IP>
cd ~/nautilus
make stop-all
make && make run       # debug: make run-debug (PCRs all zeros)
sh expose_enclave.sh   # expose 3000/9184 and inject secrets
```

### Verification
```sh
nitro-cli describe-enclaves
curl -H 'Content-Type: application/json' -X GET http://<PUBLIC_IP>:3000/health_check
curl -H 'Content-Type: application/json' -X GET http://<PUBLIC_IP>:3000/get_attestation
curl -H 'Content-Type: application/json' -d '{"payload":{"user_url":"https://x.com/.../status/..."}}' -X POST http://<PUBLIC_IP>:3000/process_data
```

### Reproduce PCRs
```sh
cd ~/nautilus && make && cat out/nitro.pcrs
```

### Troubleshooting
- SSH failure (Connection reset): open inbound `22`; ensure `chmod 600` on key; username `ec2-user`; confirm instance `running` and public IP.
- `health_check` domain false:
  - Parent proxy: `sudo pgrep -a vsock-proxy`; if not running: `sudo nohup vsock-proxy 8101 api.twitter.com 443 >/var/log/vsock-proxy-8101.log 2>&1 &`
  - Parent internet: from EC2 test `nc -vz api.twitter.com 443`
- Ports unreachable: open inbound `3000/9184` and run `sh expose_enclave.sh`.
- Reset:
```sh
cd ~/nautilus && make stop-all && make && make run && sh expose_enclave.sh
```

### Terminate instance
```sh
aws ec2 describe-instances --region us-east-1 --query "Reservations[*].Instances[*].[InstanceId,State.Name,Tags]"
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region us-east-1
```

### Environment variables
- `KEY_PAIR`: AWS Key Pair name (e.g., `aws-ec2-tee-keypair`)
- `REGION`: defaults to `us-east-1`
- `AMI_ID`: defaults to `ami-085ad6ae776d8f09c`
- `API_ENV_VAR_NAME`: defaults to `API_KEY` (injected into enclave)

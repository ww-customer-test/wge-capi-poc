# WKP CAPI Platform Cluster Management

## WKP Preview Feature Prerequisites

* Linux or Macintosh machine to run the demo.
* Docker installed and functioning.
* Mac installation instructions [link](https://docs.docker.com/docker-for-mac/install/)
* Linux installation instructions [link](https://docs.docker.com/engine/install/)
* AWS Account where clusters will be created
* IAM credentials that have permissions to create artefacts in the destination AWS account
* Create a [GitHub personal access token](https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token) with repo scope and export it:

* Weaveworks entitlement file
* Dockerhub user and api-token
* Github user/machine user and token
* Generated ssh rsa private key and public key

## Repository Setup

* Copy [this repo](https://github.com/wkp-capi-demo/paulcarlton-platform-cluster-management)

## Install client software

clone your copy of this repository.

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
cd <cloned repository directory>
./utils/install.sh
```

## Setup environmental variables

```sh
export GITHUB_TOKEN=... 

export AWS_ACCESS_KEY_ID=mykey
export AWS_SECRET_ACCESS_KEY=mysecret
export AWS_REGION=<region to use>

export GITHUB_ORG=wkp-capi-demo # or your repository org
export GITHUB_REPO=<repository name>
```

## Create the CAPI AWS IAM Artefacts

> NOTE: This is a one-time task that needs to done to setup an AWS account with the required IAM roles/policies for use by Cluster API Provider AWS

* Ensure your [AWS environment variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html) are setup as if you were using the `aws` cli
* Run the following command from the cloned repo:

```sh
clusterawsadm bootstrap iam create-cloudformation-stack --region eu-west-1 --config bootstrap.config -v 12

Attempting to create AWS CloudFormation stack cluster-api-provider-aws-sigs-k8s-io

Following resources are in the stack:

Resource                  |Type                                                                                |Status
AWS::IAM::Group           |cluster-api-provider-aws-s-AWSIAMGroupBootstrapper-1Y1WID2RLKBN2                    |CREATE_COMPLETE
AWS::IAM::InstanceProfile |control-plane.cluster-api-provider-aws.sigs.k8s.io                                  |CREATE_COMPLETE
AWS::IAM::InstanceProfile |controllers.cluster-api-provider-aws.sigs.k8s.io                                    |CREATE_COMPLETE
AWS::IAM::InstanceProfile |nodes.cluster-api-provider-aws.sigs.k8s.io                                          |CREATE_COMPLETE
AWS::IAM::ManagedPolicy   |arn:aws:iam::<account id>:policy/control-plane.cluster-api-provider-aws.sigs.k8s.io |CREATE_COMPLETE
AWS::IAM::ManagedPolicy   |arn:aws:iam::<account id>:policy/nodes.cluster-api-provider-aws.sigs.k8s.io         |CREATE_COMPLETE
AWS::IAM::ManagedPolicy   |arn:aws:iam::<account id>:policy/controllers.cluster-api-provider-aws.sigs.k8s.io   |CREATE_COMPLETE
AWS::IAM::Role            |control-plane.cluster-api-provider-aws.sigs.k8s.io                                  |CREATE_COMPLETE
AWS::IAM::Role            |controllers.cluster-api-provider-aws.sigs.k8s.io                                    |CREATE_COMPLETE
AWS::IAM::Role            |eks-controlplane.cluster-api-provider-aws.sigs.k8s.io                               |CREATE_COMPLETE
AWS::IAM::Role            |eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io                                  |CREATE_COMPLETE
AWS::IAM::Role            |nodes.cluster-api-provider-aws.sigs.k8s.io                                          |CREATE_COMPLETE
AWS::IAM::User            |bootstrapper.cluster-api-provider-aws.sigs.k8s.io                                   |CREATE_COMPLETE
```

* Wait for the CloudFormation stack to be created (you can view its progress in the AWS Console in the CloudFormation service)
* Go to the IAM service in the AWS Console
* Go to the bootstrapper.cluster-api-provider-aws.sigs.k8s.io user and create a new access key
* Export the access key id and access key secret as they will be used as part of bootstrap:

## Bootstrap Process

The bootstrap script will create a local Kind cluster, deploy Cluster API and then use this to provision an EKS controller cluster. It will then use the EKS controller cluster to provision two tenant clusters in separate AWS accounts.

The credentials for the two accounts will be sourced from files in the directory referenced by the CREDS_DIR environmental variable if set or the users home directory if CREDS_DIR is not specified. The script will look for account-one.sh and account-two.sh files in this directory.

```
./utils/bootstrap.sh
```

Optionally the following parameters can be supplied. Any parameters not supplied will default to the relevant environmental variable.

```
    aws-access-key-id=${AWS_ACCESS_KEY_ID}
    aws-secret-access-key=${AWS_SECRET_ACCESS_KEY}
    region=${AWS_REGION:-eu-west-1}
    github-user=${GITHUB_USER:-$(git config -f ~/.gitconfig --get user.name)}
    github-org=${GITHUB_ORG:-$(git config -f ~/.gitconfig --get user.name)}
    github-repo=${GITHUB_REPO:-$(basename $(git rev-parse --show-toplevel))}
    github-token=${GITHUB_TOKEN}
    mgmt-cluster-def-file=${MGMT_CLUSTER_DEF_FILE:-./cluster-specs/bootstrap/eks-mgmt/eks-mgmt.yaml}
    creds-dir=${CREDS_DIR:-$HOME}
    keep-kind=true
```

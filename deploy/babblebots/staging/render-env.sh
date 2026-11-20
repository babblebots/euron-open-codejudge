#!/bin/bash
# Writes /opt/euron/.env from SSM Parameter Store, so secrets never leave AWS.
# Usage: TAG=<image tag> ./render-env.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${TAG:?set TAG to the image tag to run}"
REGION=ap-south-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
umask 077
{
  echo "TAG=$TAG"
  echo "REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  echo "EURON_HOSTNAME=code-staging.babblebots.ai"
  echo "OBJECTS_BUCKET=babblebots-euron-staging-objects"
  echo "CORS_ORIGINS=https://interview-staging.babblebots.ai"
  aws ssm get-parameters-by-path --region "$REGION" --path /euron-staging/ --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text |
    while read -r name value; do echo "${name##*/}=$value"; done
} > .env
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com" >/dev/null
echo "wrote .env ($(wc -l < .env) lines), logged in to ECR"

#!/bin/bash
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o pipefail

handle_error() {
    local exit_code=$?
    exit $exit_code
}
trap 'handle_error' ERR

while getopts p:t: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        t) IMAGE_TAG=${OPTARG};;
    esac
done

# Iterate over the infra manager location to identify the deployment
# currently one deployment per project is only supported
# in future if multiple deployments are supported per project this will need to change
IM_SUPPORTED_REGIONS=("us-central1" "europe-west1" "asia-east1")

for REGION in "${IM_SUPPORTED_REGIONS[@]}"; do
    DEPLOYMENT_NAME=$(gcloud infra-manager deployments list --location "${REGION}" \
                        --filter="labels.goog-solutions-console-deployment-name:* AND \
                        labels.goog-solutions-console-solution-id:three-tier-web-app" \
                        --format='value(name)' )
    if [ -n "$DEPLOYMENT_NAME" ]; then
        break
    fi
done
if [ -z "$DEPLOYMENT_NAME" ]; then
	echo "Failed to find the existing deployment, exiting now!"
	exit 1
fi
echo "Project ID is ${PROJECT_ID}"
echo "Region is ${REGION}"
echo "Deployment name is ${DEPLOYMENT_NAME}"
echo "IMAGE_TAG is ${IMAGE_TAG}"

SERVICE_ACCOUNT=$(gcloud infra-manager deployments describe ${DEPLOYMENT_NAME} --location ${REGION} --format='value(serviceAccount)')

echo "Assigning required roles to the service account ${SERVICE_ACCOUNT}"
# Iterate over the roles and check if the service account already has that role
# assigned. If it has then skip adding that policy binding as using
# --condition=None can overwrite any existing conditions in the binding.
CURRENT_POLICY=$(gcloud projects get-iam-policy ${PROJECT_ID} --format=json)
MEMBER_EMAIL=$(echo ${SERVICE_ACCOUNT} | awk -F '/' '{print $NF}')
MEMBER="serviceAccount:${MEMBER_EMAIL}"
apt-get install jq -y
while IFS= read -r role || [[ -n "$role" ]]
do \
if echo "$CURRENT_POLICY" | jq -e --arg role "$role" --arg member "$MEMBER" '.bindings[] | select(.role == $role) | .members[] | select(. == $member)' > /dev/null; then \
    echo "IAM policy binding already exists for member ${MEMBER} and role ${role}"
else \
    gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="$MEMBER" \
    --role="$role" \
    --condition=None
fi
done < "roles.txt"

cd ./src/middleware
gcloud builds submit --config=./cloudbuild.yaml --substitutions=_IMAGE_TAG="${IMAGE_TAG}"
cd -
cd ./src/frontend
gcloud builds submit --config=./cloudbuild.yaml --substitutions=_IMAGE_TAG="${IMAGE_TAG}"
cd -

DEPLOYMENT_DESCRIPTION=$(gcloud infra-manager deployments describe ${DEPLOYMENT_NAME} --location ${REGION} --format json)
cat <<EOF > input.tfvars
# Do not edit the region as changing the region can lead to failed deployment.
region="$(echo $DEPLOYMENT_DESCRIPTION | jq -r '.terraformBlueprint.inputValues.region.inputValue')"
zone="$(echo $DEPLOYMENT_DESCRIPTION | jq -r '.terraformBlueprint.inputValues.zone.inputValue')"
project_id = "${PROJECT_ID}"
deployment_name = "${DEPLOYMENT_NAME}"
fe_image_name="gcr.io/${PROJECT_ID}/three-tier-app-fe:${IMAGE_TAG}"
be_image_name="gcr.io/${PROJECT_ID}/three-tier-app-be:${IMAGE_TAG}"
labels = {
  "goog-solutions-console-deployment-name" = "${DEPLOYMENT_NAME}",
  "goog-solutions-console-solution-id" = "three-tier-web-app"
}
EOF

echo "Creating the cloud storage bucket if it does not exist already"
BUCKET_NAME="${PROJECT_ID}_infra_manager_staging"
if ! gsutil ls "gs://$BUCKET_NAME" &> /dev/null; then
    gsutil mb "gs://$BUCKET_NAME/"
    echo "Bucket $BUCKET_NAME created successfully."
else
    echo "Bucket $BUCKET_NAME already exists. Moving on to the next step."
fi

echo "Deploying the solution"
gcloud infra-manager deployments apply projects/${PROJECT_ID}/locations/${REGION}/deployments/${DEPLOYMENT_NAME} --service-account ${SERVICE_ACCOUNT} --local-source="."     --inputs-file=./input.tfvars --labels="modification-reason=make-it-mine,goog-solutions-console-deployment-name=${DEPLOYMENT_NAME},goog-solutions-console-solution-id=three-tier-web-app,goog-config-partner=sc"

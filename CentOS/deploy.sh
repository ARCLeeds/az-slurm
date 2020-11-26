#!/bin/bash

. private.sh


ACTION=${1-validate}

echo $ACTION

az deployment group $ACTION --name azure-slurm-test --resource-group $RG --template-file azuredeploy.json --parameters azuredeploy.parameters.json

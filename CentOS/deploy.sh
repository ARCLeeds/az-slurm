#!/bin/bash

. private.sh

az deployment group create --name azure-slurm-test --resource-group $RG --template-file azuredeploy.json --parameters azuredeploy.parameters.json

./azuread-user.sh

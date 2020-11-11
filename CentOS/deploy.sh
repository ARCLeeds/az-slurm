#!/bin/bash

. private.sh

az deployment group create --resource-group uol_it_rc_slurm_test --template-file azuredeploy.json --parameters azuredeploy.parameters.json

./azuread.sh
./azuread-user.sh

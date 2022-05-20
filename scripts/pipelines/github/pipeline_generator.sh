#!/bin/bash
set -e
FLAGS=$(getopt -a --options c:n:d:a:b:l:i:u:p:hw --long "config-file:,pipeline-name:,local-directory:,artifact-path:,target-branch:,language:,build-pipeline-name:,sonar-url:,sonar-token:,image-name:,registry-user:,registry-password:,resource-group:,storage-account:,storage-container:,cluster-name:,s3-bucket:,s3-key-path:,quality-pipeline-name:,dockerfile:,test-pipeline-name:,aws-access-key:,aws-secret-access-key:,aws-region:,help" -- "$@")

eval set -- "$FLAGS"
while true; do
    case "$1" in
        -c | --config-file)       configFile=$2; shift 2;;
        -n | --pipeline-name)     export pipelineName=$2; shift 2;;
        -d | --local-directory)   localDirectory=$2; shift 2;;
        -a | --artifact-path)     artifactPath=$2; shift 2;;
        -b | --target-branch)     targetBranch=$2; shift 2;;
        -l | --language)          language=$2; shift 2;;
        --build-pipeline-name)    export buildPipelineName=$2; shift 2;;
        --sonar-url)              sonarUrl=$2; shift 2;;
        --sonar-token)            sonarToken=$2; shift 2;;
        -i | --image-name)        imageName=$2; shift 2;;
        -u | --registry-user)     dockerUser=$2; shift 2;;
        -p | --registry-password) dockerPassword=$2; shift 2;;
        --resource-group)         resourceGroupName=$2; shift 2;;
        --storage-account)        storageAccountName=$2; shift 2;;
        --storage-container)      storageContainerName=$2; shift 2;;
        --cluster-name)           clusterName=$2; shift 2;;
        --s3-bucket)              s3Bucket=$2; shift 2;;
        --s3-key-path)            s3KeyPath=$2; shift 2;;
        --quality-pipeline-name)  export qualityPipelineName=$2; shift 2;;
        --test-pipeline-name)     export testPipelineName=$2; shift 2;;
        --dockerfile)             dockerFile=$2; shift 2;;
        --aws-access-key)         awsAccessKey="$2"; shift 2;;
        --aws-secret-access-key)  awsSecretAccessKey="$2"; shift 2;;
        --aws-region)             awsRegion="$2"; shift 2;;
        -h | --help)              help="true"; shift 1;;
        -w)                       webBrowser="true"; shift 1;;
        --) shift; break;;
    esac
done

# Colours for the messages.
white='\e[1;37m'
green='\e[1;32m'
red='\e[0;31m'

# Loading common function
# Common var
commonTemplatesPath="scripts/pipelines/github/templates/common"

function help {
    echo ""
    echo "Generates a pipeline on Azure DevOps based on the given definition."
    echo ""
    echo "Common flags:"
    echo "  -c, --config-file           [Required] Configuration file containing pipeline definition."
    echo "  -n, --pipeline-name         [Required] Name that will be set to the pipeline."
    echo "  -d, --local-directory       [Required] Local directory of your project (the path should always be using '/' and not '\')."
    echo "  -a, --artifact-path                    Path to be persisted as an artifact after pipeline execution, e.g. where the application stores logs or any other blob on runtime."
    echo "  -b, --target-branch                    Name of the branch to which the Pull Request will target. PR is not created if the flag is not provided."
    echo "  -w                                     Open the Pull Request on the web browser if it cannot be automatically merged. Requires -b flag."
    echo ""
    echo "Build pipeline flags:"
    echo "  -l, --language              [Required] Language or framework of the project."
    echo ""
    echo "Test pipeline flags:"
    echo "  -l, --language              [Required] Language or framework of the project."
    echo "      --build-pipeline-name   [Required] Build pipeline name."
    echo ""
    echo "Quality pipeline flags:"
    echo "  -l, --language              [Required] Language or framework of the project."
    echo "      --sonar-url             [Required] Sonarqube URL."
    echo "      --sonar-token           [Required] Sonarqube token."
    echo "      --build-pipeline-name   [Required] Build pipeline name."
    echo "      --test-pipeline-name    [Required] Test pipeline name."
    echo ""
    echo "Package pipeline flags:"
    echo "  -l, --language              [Required, if dockerfile not set] Language or framework of the project."
    echo "      --dockerfile            [Required, if language not set] Path from the root of the project to its Dockerfile. Takes precedence over the language/framework default one."
    echo "      --build-pipeline-name   [Required] Build pipeline name."
    echo "      --quality-pipeline-name [Required] Quality pipeline name."
    echo "  -i, --image-name            [Required] Name (excluding tag) for the generated container image."
    echo "  -u, --registry-user         [Required, unless AWS] Container registry login user."
    echo "  -p, --registry-password     [Required, unless AWS] Container registry login password."
    echo "      --aws-access-key        [Required, if AWS] AWS account access key ID. Takes precedence over registry credentials."
    echo "      --aws-secret-access-key [Required, if AWS] AWS account secret access key."
    echo "      --aws-region            [Required, if AWS] AWS region for ECR."
    echo ""
    echo "Library package pipeline flags:"
    echo "  -l, --language              [Required] Language or framework of the project."
    echo ""
    echo "Deploy pipeline flags:"
    echo ""
    echo "Azure AKS provisioning pipeline flags:"
    echo "      --resource-group        [Required] Name of the resource group for the cluster."
    echo "      --storage-account       [Required] Name of the storage account for the cluster."
    echo "      --storage-container     [Required] Name of the storage container where the Terraform state of the cluster will be stored."
    echo ""
    echo "AWS EKS provisioning pipeline flags:"
    echo "      --cluster-name          [Required] Name for the cluster."
    echo "      --s3-bucket             [Required] Name of the S3 bucket where the Terraform state of the cluster will be stored."
    echo "      --s3-key-path           [Required] Path within the S3 bucket where the Terraform state of the cluster will be stored."

    exit
}


function checkInstallations {
    # Check if Git is installed
    if ! [ -x "$(command -v git)" ]; then
        echo -e "${red}Error: Git is not installed." >&2
        exit 127
    fi

    # Check if Azure CLI is installed
    if ! [ -x "$(command -v gh)" ]; then
        echo -e "${red}Error: Github CLI is not installed." >&2
        exit 127
    fi

    # Check if Python is installed
    if ! [ -x "$(command -v python)" ]; then
        echo -e "${red}Error: Python is not installed." >&2
        exit 127
    fi
}

function obtainHangarPath {
pipelineGeneratorFullPath=$(readlink -f "$(pwd)/$0")
pipelineGeneratorRepoPath='/scripts/pipelines/github/pipeline_generator.sh'
# replace the repo path in the full path with an empty string
hangarPath=${pipelineGeneratorFullPath/$pipelineGeneratorRepoPath}
}

# Function that adds the variables to be used in the pipeline.
function addCommonPipelineVariables {
    if test -z ${artifactPath}
    then
        echo "Skipping creation of the variable artifactPath as the flag has not been used."
        # Delete the commentary to set the artifactPath input/var
        sed -i '/# mark to insert additional artifact input #/d' "${localDirectory}/${pipelinePath}/${yamlFile}"
        sed -i '/# mark to insert additional artifact env var #/d' "${localDirectory}/${pipelinePath}/${yamlFile}"
    else
        # add the input for the additional artifact
        grep "    inputs:" ${localDirectory}/${pipelinePath}/${yamlFile} > /dev/null && textArtifactPathInput="      artifactPath:\n       required: false\n       default: ${artifactPath//\//\\/}"
        grep "    inputs:" ${localDirectory}/${pipelinePath}/${yamlFile} > /dev/null || textArtifactPathInput="    inputs:\n      artifactPath:\n       required: false\n       default: \"${artifactPath//\//\\/}\""
        sed -i "s/# mark to insert additional artifact input #/$textArtifactPathInput/" "${localDirectory}/${pipelinePath}/${yamlFile}"
        # add the env var for the additional artifact
        grep "^env:" ${localDirectory}/${pipelinePath}/${yamlFile} > /dev/null && textArtifactPathVar="  artifactPath: \${{ github.event_name == 'push' \&\& format('${artifactPath//\//\\/}') || github.event.inputs.artifactPath }}"
        grep "^env:" ${localDirectory}/${pipelinePath}/${yamlFile} > /dev/null || textArtifactPathVar="env:\n  artifactPath: \${{ github.event_name == 'push' \&\& format('${artifactPath//\//\\/}') || github.event.inputs.artifactPath }}"
        # Add the extra artifact to store variable.
        sed -i "s/# mark to insert additional artifact env var #/$textArtifactPathVar/" "${localDirectory}/${pipelinePath}/${yamlFile}"
    fi
}

function createPR {
    # Check if a target branch is supplied.
    if test -z "$targetBranch"
    then
        # No branch specified in the parameters, no Pull Request is created, the code will be stored in the current branch.
        echo -e "${green}No branch specified to do the Pull Request, changes left in the ${sourceBranch} branch."
        exit
    else
        echo -e "${green}Creating a Pull Request..."
        echo -ne ${white}
        repoURL=$(git config --get remote.origin.url)
        repoNameWithGit="${repoURL/https:\/\/github.com\/}"
        repoName="${repoNameWithGit/.git}"
        # Create the Pull Request to merge into the specified branch.
        #debug
        echo "gh pr create -B \"$targetBranch\" -b \"merge request build pipeline\" -H feature/build-pipeline -R \"${repoName}\" -t \"Build Pipeline\""
        pr=$(gh pr create -B "$targetBranch" -b "merge request build pipeline" -H feature/build-pipeline -R "${repoName}" -t "Build Pipeline")

        # trying to merge
        if gh pr merge -s "$pr"
        then
            # Pull Request merged successfully.
            echo -e "${green}Pull Request merged into $targetBranch branch successfully."
            exit
        else
            # Check if the -w flag is activated.
            if [[ "$webBrowser" == "true" ]]
            then
                # -w flag is activated and a page with the corresponding Pull Request is opened in the web browser.
                echo -e "${green}Pull Request successfully created."
                echo -e "${green}Opening the Pull Request on the web browser..."
                python -m webbrowser "$pr"
                exit
            else
                # -w flag is not activated and the URL to the Pull Request is shown in the console.
                echo -e "${green}Pull Request successfully created."
                echo -e "${green}To review the Pull Request and accept it, click on the following link:"
                echo "${pr}"
                exit
            fi
        fi
    fi
}

if [[ "$help" == "true" ]]; then help; fi

obtainHangarPath

# Load common functions
. "$hangarPath/scripts/pipelines/common/pipeline_generator.lib"

ensurePathFormat

importConfigFile

checkInstallations

createNewBranch

copyYAMLFile

copyCommonScript

type copyScript &> /dev/null && copyScript

# This function does not exists for the github pipeline generator at this moment, but I let the line with 'type' to keep the same structure as the others pipeline generator
type addCommonPipelineVariables &> /dev/null && addCommonPipelineVariables

type addPipelineVariables &> /dev/null && addPipelineVariables

commitCommonFiles

type commitFiles &> /dev/null && commitFiles

# createPipeline

createPR

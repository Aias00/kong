pipeline {
  agent {
    node {
      label 'hybrid'
    }
  }
  options {
      timeout(time: 45, unit: 'MINUTES')
  }
  environment {
    GITHUB_TOKEN = credentials('github_bot_access_token')
    REDHAT = credentials('redhat')
    PULP = credentials('PULP')
    DOCKERHUB_KONGCLOUD_PUSH = credentials('DOCKERHUB_KONGCLOUD_PUSH')
    PRIVATE_KEY_FILE = credentials('kong.private.gpg-key.asc')
    PRIVATE_KEY_PASSWORD = credentials('kong.private.gpg-key.asc.password')
    // This cache dir will contain files owned by root, and user ubuntu will
    // not have permission over it. We still need for it to survive between
    // builds, so /tmp is also not an option. Try $HOME for now, iterate
    // on that
    CACHE_DIR = "$HOME/kong-distributions-cache"
    //KONG_VERSION = """${sh(
    //  returnStdout: true,
    //  script: '[ -n $TAG_NAME ] && echo $TAG_NAME | grep -o -P "\\d+\\.\\d+\\.\\d+\\.\\d+" || echo -n $BRANCH_NAME | grep -o -P "\\d+\\.\\d+\\.\\d+\\.\\d+"'
    //)}"""
    // XXX: Can't bother to fix this now. This works, right? :)
    KONG_VERSION = "2.7.0.0"
  }
  stages {
    // choice between internal, rc1, rc2, rc3, rc4 ....,  GA
    stage('Checkpoint') {
      steps {
        script {
          def input_params = input(
            message: "Kong Enteprise Edition",
            parameters: [
              // Add any needed input here (look for available parameters)
              // https://www.jenkins.io/doc/book/pipeline/syntax/
              choice(
                name: 'release_scope',
                description: 'What is the release scope?',
                choices: [
                  'internal-preview',
                  'beta1', 'beta2',
                  'rc1', 'rc2', 'rc3', 'rc4', 'rc5',
                  'ga'
                ]
              )
            ]
          )
          env.RELEASE_SCOPE = input_params
        }
      }
    }
    // This can be run in different nodes in the future \0/
    stage('Build & Push Packages') {
      steps {
        parallel (
          centos7: {
            sh "./dist/dist.sh build centos:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign centos:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test centos:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p centos:7 -e -R ${env.RELEASE_SCOPE}"
          },
          centos8: {
            sh "./dist/dist.sh build centos:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign centos:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test centos:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p centos:8 -e -R ${env.RELEASE_SCOPE}"
          },
          debian8: {
            sh "./dist/dist.sh build debian:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test debian:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p debian:8 -e -R ${env.RELEASE_SCOPE}"
          },
          debian9: {
            sh "./dist/dist.sh build debian:9 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test debian:9 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p debian:9 -e -R ${env.RELEASE_SCOPE}"
          },
          debian10: {
            sh "./dist/dist.sh build debian:10 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test debian:10 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p debian:10 -e -R ${env.RELEASE_SCOPE}"
          },
          debian11: {
            sh "./dist/dist.sh build debian:11 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test debian:11 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p debian:11 -e -R ${env.RELEASE_SCOPE}"
          },
          ubuntu1604: {
            sh "./dist/dist.sh build ubuntu:16.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test ubuntu:16.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p ubuntu:16.04 -e -R ${env.RELEASE_SCOPE}"
          },
          ubuntu1804: {
            sh "./dist/dist.sh build ubuntu:18.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test ubuntu:18.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p ubuntu:18.04 -e -R ${env.RELEASE_SCOPE}"
          },
          ubuntu2004: {
            sh "./dist/dist.sh build ubuntu:20.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test ubuntu:20.04 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p ubuntu:20.04 -e -R ${env.RELEASE_SCOPE}"
          },
          amazonlinux1: {
            sh "./dist/dist.sh build amazonlinux:1 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign amazonlinux:1 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test amazonlinux:1 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p amazonlinux:1 -e -R ${env.RELEASE_SCOPE}"
          },
          amazonlinux2: {
            sh "./dist/dist.sh build amazonlinux:2 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign amazonlinux:2 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test amazonlinux:2 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p amazonlinux:2 -e -R ${env.RELEASE_SCOPE}"
          },
          alpine: {
            sh "./dist/dist.sh build alpine ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test alpine ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p alpine -e -R ${env.RELEASE_SCOPE}"
          },
          rhel7: {
            sh "./dist/dist.sh build rhel:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign rhel:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test rhel:7 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p rhel:7 -e -R ${env.RELEASE_SCOPE}"
          },
          rhel8: {
            sh "./dist/dist.sh build rhel:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh sign rhel:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh test rhel:8 ${env.RELEASE_SCOPE}"
            sh "./dist/dist.sh release -H prod -V -u $PULP_USR -k $PULP_PSW -p rhel:8 -e -R ${env.RELEASE_SCOPE}"
          },
        )
      }
    }
    stage("Build & Push Docker Images") {
      steps {
        parallel (
          // beware! $KONG_VERSION might have an ending \n that swallows everything after it
          alpine: {
            sh "./dist/dist.sh docker-hub-release -u $DOCKERHUB_KONGCLOUD_PUSH_USR \
                                                  -k $DOCKERHUB_KONGCLOUD_PUSH_PSW \
                                                  -pu $PULP_USR \
                                                  -pk $PULP_PSW \
                                                  -p alpine \
                                                  -R ${env.RELEASE_SCOPE} \
                                                  -v $KONG_VERSION"
          },
          centos7: {
            sh "./dist/dist.sh docker-hub-release -u $DOCKERHUB_KONGCLOUD_PUSH_USR \
                                                  -k $DOCKERHUB_KONGCLOUD_PUSH_PSW \
                                                  -pu $PULP_USR \
                                                  -pk $PULP_PSW \
                                                  -p centos \
                                                  -R ${env.RELEASE_SCOPE} \
                                                  -v $KONG_VERSION"
          },
          rhel: {
            sh "./dist/dist.sh docker-hub-release -u $DOCKERHUB_KONGCLOUD_PUSH_USR \
                                                  -k $DOCKERHUB_KONGCLOUD_PUSH_PSW \
                                                  -pu $PULP_USR \
                                                  -pk $PULP_PSW \
                                                  -p rhel \
                                                  -R ${env.RELEASE_SCOPE} \
                                                  -v $KONG_VERSION"
          },
        )
      }
    }
  }
}

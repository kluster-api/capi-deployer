# AWS

* `wget`
* `nats-logger`
* `kubectl`
* `helm`
* `clusterctl:v1.6.3`
* `capi-config-linux-amd64`
* `clusterawsadm:v2.4.2`
* `aws cli`
* `eksctl`
* `aws-iam-authenticator: 0.6.14`
* `infrustructure config files` `/home/ubuntu/assets/config.yaml`

Size: 1.3GB

### Test container
```bash
make container
docker run -ti --rm <REGISTRY>/capa-deployer:_linux_amd64 /bin/bash
```
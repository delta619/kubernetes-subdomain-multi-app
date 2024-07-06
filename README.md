Welcome to my repo about Kubernetes.
In this repo, the skeleton of this infra would be able to deploy multiple services or apps having different subdomain yet same domain name. eg. 
- walmart.wd5.myworkdayjobs.com -> springboot application
- quickenloans.wd5.myworkdayjobs.com -> node application

To setup a similar infrastructure where subdomains refer to different services, please refer to the template for ssl and easy deployment.

1. Inside `kube-infrastructure` folder, execute `make install_infra` to set up the infrastructure of the kubernetes ingress and ssl plugins
2. Inside subdomain1 or subdomain2 modify the templates and values accordingly to point to your docker image and port.
3. Deploy that subdomain<?> app using `make install_app`
4. Don't forget to mention the domain config inside `echo_ingress` file.

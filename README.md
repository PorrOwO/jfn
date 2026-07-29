#JFN
## Dependencies
- docker
- docker-compose
- java jdk21
- jolie:
  - Be sure to have the `$JOLIE_HOME` enviroment variable set
- jocker:
  - run `git submodule update --init --recursive` to automatically clone it after cloning this repository

## Building
To build the jfn source code navigate to the project root directory and run `make`.
To build the docker images necessaries to run jfn, in the project root directory run `make -C docker`

## Running
Go inside the `docker/` folder and run `docker-compose up -d` and everything should be up and running.
To check if everything is working you can run the following command:
```sh
curl -X POST http://localhost:8000/op \
     -H "Content-Type: application/json" \
     -d '{"fn": "hello", "data": "my-name"}'
```
If everything is set up correctly the response will be:
```sh
{"data":"Hello porrowo!","error":false}
```
### Fedora/SELinux
If you are running Fedora or any other Linux distribution that uses SELinux in *enforcing* mode, you will encounter permission issues.
By default, SELinux prevents the `jocker` container from accessing the host's Docker socket, and blocks the `catalog` container from reading host-mounted function directories.
For now, you can work around this by explicitly bypassing the SELinux restrictions for these specific services.
Ensure your `docker-compose.yaml` includes the `privileged` and `security_opt` flags for `jocker`, and appends the `:z` flag to the `catalog` volume mount:

```yaml
  jocker:
    image: jolielang/jocker
    privileged: true                       # Required for deep container orchestration
    volumes:
      - /var/run:/var/run
    security_opt:
      - label:disable                      # Workaround to bypass SELinux socket blocking
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    networks:
      - jfn

  catalog:
    image: jfn/function_catalog
    environment:
      - FUNCTION_CATALOG_LOCATION=socket://0.0.0.0:8002
      - VERBOSE=true
    volumes:
      - ../functions:/app/functions:z       # :z flag allows the container to read the host directory
    networks:
      - jfn
```
## Adding your functions
In the `functions/` folder there are already some example functions to be run, you can add any functions you write to that folder to have it available to the function catalog.

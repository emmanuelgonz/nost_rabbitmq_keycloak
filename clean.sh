#!/bin/bash
sudo docker stop $(sudo docker ps -q)
sudo docker rm $(sudo docker ps -a -q)
sudo docker image prune -a
sudo docker network prune
#sudo rm -rf acme/ certs/ html/ vhost/

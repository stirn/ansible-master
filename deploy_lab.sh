#!/bin/bash

script_path=$(readlink -f "$0")
script_dir=$(dirname "$script_path")

docker_compose_yml=${script_dir}/docker-compose.yml

TARGET_COUNT=2
TARGET_BASE_NAME="ansible_ziel"
MASTER_BASE_NAME="ansible_meister"

DB_VOLUME_NAME="semaphore-postgres"

ANSIBLE_SSH_PORT=30022
SEMAPHORE_HTTP_PORT=5000

PASSWORD_FILE="${script_dir}/pass.json"
HOST_SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)

GIT_REPO=$(git remote get-url --all origin)

dexec() {
  docker exec -i "$1" bash -c "$2"
}

docker compose down
docker volume rm "$(basename ${script_dir})"_${DB_VOLUME_NAME}
rm -rf "${PASSWORD_FILE}" "${docker_compose_yml}"

if [ -f "${PASSWORD_FILE}" ]; then
  echo "--- Reading passwords from ${PASSWORD_FILE}"
  POSTGRES_PASSWORD=$(jq -r '.POSTGRES_PASSWORD' "${PASSWORD_FILE}")
  SEMAPHORE_ADMIN_PASSWORD=$(jq -r '.SEMAPHORE_ADMIN_PASSWORD' "${PASSWORD_FILE}")
  SEMAPHORE_ACCESS_KEY_ENCRYPTION=$(jq -r '.SEMAPHORE_ACCESS_KEY_ENCRYPTION' "${PASSWORD_FILE}")

else
  echo "--- Creating passwords file ${PASSWORD_FILE}"
  POSTGRES_PASSWORD=$(cat /dev/urandom | LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
  SEMAPHORE_ADMIN_PASSWORD=$(cat /dev/urandom | LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
  SEMAPHORE_ACCESS_KEY_ENCRYPTION=$(cat /dev/urandom | LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

  cat <<EOF >"${PASSWORD_FILE}"
{
"POSTGRES_PASSWORD": "$POSTGRES_PASSWORD",
"SEMAPHORE_ADMIN_PASSWORD": "$SEMAPHORE_ADMIN_PASSWORD",
"SEMAPHORE_ACCESS_KEY_ENCRYPTION": "$SEMAPHORE_ACCESS_KEY_ENCRYPTION"
}
EOF

fi

cat <<EOF >"${docker_compose_yml}" &&
\
version: '3.1'
services:

  ${MASTER_BASE_NAME}:
    image: ubuntu
    container_name: ${MASTER_BASE_NAME}
    restart: no
    networks:
      - 'ansible'
    ports:
      - ${ANSIBLE_SSH_PORT}:22
    command: >
      bash -c "apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server git ansible \
        && mkdir -p /run/sshd && chmod 0755 /run/sshd \
        && service ssh start \
        && tail -f /dev/null"
\
EOF
    echo "--- Appended ${MASTER_BASE_NAME} to ${docker_compose_yml}"

counter=1
while [ $counter -le ${TARGET_COUNT} ]; do
    cat <<EOF >>"${docker_compose_yml}" &&
\
  ${TARGET_BASE_NAME}${counter}:
    image: ubuntu
    container_name: ${TARGET_BASE_NAME}${counter}
    restart: no
    networks:
      - 'ansible'
    command: >
      bash -c "apt-get update \
        && apt-get install -y openssh-server \
        && mkdir -p /run/sshd && chmod 0755 /run/sshd \
        && service ssh start \
        && tail -f /dev/null"
\
EOF
    echo "--- Appended ${TARGET_BASE_NAME}${counter} to ${docker_compose_yml}"
    ((counter++))
done

cat <<EOF >>"${docker_compose_yml}" &&
\
  postgres:
    restart: unless-stopped
    image: postgres:14
    container_name: postgres
    networks:
        - 'ansible'
    volumes: 
      - ${DB_VOLUME_NAME}:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: semaphore
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: semaphore
  semaphore:
    restart: unless-stopped
    ports:
      - ${SEMAPHORE_HTTP_PORT}:3000
    image: semaphoreui/semaphore:latest
    container_name: semaphore
    networks:
        - 'ansible'
    environment:
      SEMAPHORE_DB_USER: semaphore
      SEMAPHORE_DB_PASS: ${POSTGRES_PASSWORD}
      SEMAPHORE_DB_HOST: postgres
      SEMAPHORE_DB_PORT: 5432
      SEMAPHORE_DB_DIALECT: postgres
      SEMAPHORE_DB: semaphore
      SEMAPHORE_PLAYBOOK_PATH: /tmp/semaphore/
      SEMAPHORE_ADMIN_PASSWORD: ${SEMAPHORE_ADMIN_PASSWORD}
      SEMAPHORE_ADMIN_NAME: admin
      SEMAPHORE_ADMIN_EMAIL: admin@localhost
      SEMAPHORE_ADMIN: admin
      SEMAPHORE_ACCESS_KEY_ENCRYPTION: ${SEMAPHORE_ACCESS_KEY_ENCRYPTION}
      SEMAPHORE_LDAP_ACTIVATED: 'no' # if you wish to use ldap, set to: 'yes' 
      SEMAPHORE_LDAP_HOST: dc01.local.example.com
      SEMAPHORE_LDAP_PORT: '636'
      SEMAPHORE_LDAP_NEEDTLS: 'yes'
      SEMAPHORE_LDAP_DN_BIND: 'uid=bind_user,cn=users,cn=accounts,dc=local,dc=shiftsystems,dc=net'
      SEMAPHORE_LDAP_PASSWORD: 'ldap_bind_account_password'
      SEMAPHORE_LDAP_DN_SEARCH: 'dc=local,dc=example,dc=com'
      SEMAPHORE_LDAP_SEARCH_FILTER: "(\u0026(uid=%s)(memberOf=cn=ipausers,cn=groups,cn=accounts,dc=local,dc=example,dc=com))"
    depends_on:
      - postgres
  
volumes:
  semaphore-postgres:
    driver: local

networks:
  ansible:
    driver: bridge

EOF
  echo "--- Appended the rest to ${docker_compose_yml}"

docker compose up -d &&
  {
    sleep 10
    echo "--- CONTAINERS DONE"
  } ||
  {
    echo "--- FAILED!"
    exit 1
  }

echo
echo "--- NOW WE WORK INSIDE CONTAINERS"
echo

echo "--- ANSIBLE MEISTER"

counter=1
until dexec ${MASTER_BASE_NAME} "apt-get check" 2>/dev/null; do
  echo "----- Waiting for container to install software..."
  sleep 3
done

dexec ${MASTER_BASE_NAME} "mkdir ~/.ssh && ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519"
MEISTER_PUBLIC_KEY=$(dexec ${MASTER_BASE_NAME} "cat ~/.ssh/id_ed25519.pub")

new_pass_file=$(jq --arg key "MEISTER_PUBLIC_KEY" --arg value "$MEISTER_PUBLIC_KEY" '. + {($key): $value}' "$PASSWORD_FILE")
echo "$new_pass_file" >"$PASSWORD_FILE"

echo "--- TARGETS"
while [ $counter -le ${TARGET_COUNT} ]; do
  echo "----- Adding MEISTER_PUBLIC_KEY to ${TARGET_BASE_NAME}${counter} ssh authorized keys"
  dexec ${TARGET_BASE_NAME}${counter} "mkdir ~/.ssh/ && echo ${MEISTER_PUBLIC_KEY} >> ~/.ssh/authorized_keys"
  echo "----- Adding ${TARGET_BASE_NAME}${counter} ssh key to known hosts"
  dexec ${MASTER_BASE_NAME} "ssh-keyscan ${TARGET_BASE_NAME}${counter} >> ~/.ssh/known_hosts"
  ((counter++))
done

echo "----- Adding this repo clone command to ${MASTER_BASE_NAME} root dir"
dexec ${MASTER_BASE_NAME} "cat > ~/clone.sh" <<EOF
#!/bin/bash
git clone $GIT_REPO
EOF

echo "----- Adding this HOST_SSH_KEY to authorized_keys at ${MASTER_BASE_NAME}"
dexec ${MASTER_BASE_NAME} "echo ${HOST_SSH_KEY} > ~/.ssh/authorized_keys"

echo "----- Adding script to ssh to ${MASTER_BASE_NAME} > jump_to_${MASTER_BASE_NAME}.sh"
cat <<EOF >>"jump_to_${MASTER_BASE_NAME}.sh" &&
\
#!/bin/bash
ssh root@localhost -p ${ANSIBLE_SSH_PORT}
EOF
  chmod 700 jump_to_${MASTER_BASE_NAME}.sh

FROM ubuntu:18.04

ENV LC_ALL=C

# Install build dependencies
############################
RUN dpkg --add-architecture i386 \
 && apt update -y \
 && apt dist-upgrade -y \
 && apt install -y android-tools-adb bc bison bsdmainutils build-essential ccache cgpt cron curl \
        flex gcc-multilib git git-core g++-multilib gnupg gperf imagemagick kmod lib32ncurses5-dev \
        lib32readline-dev lib32z1-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
        libwxgtk3.0-dev libxml2 libxml2-utils lsof lzop make maven openjdk-8-jdk pngcrush procps python \
        rsync schedtool software-properties-common squashfs-tools sudo vim wget xdelta3 xsltproc yasm \
        zip zlib1g-dev zlib1g-dev:i386

# Download and build tools
##########################
RUN mkdir -p /srv/tools/bin /srv/tools/delta \
 && cd /srv/tools \
 && wget 'https://storage.googleapis.com/git-repo-downloads/repo' -P /srv/tools/bin \
 && chmod +x /srv/tools/bin/repo \
 && git clone --depth=1 https://github.com/ionphractal/android_packages_apps_OpenDelta.git OpenDelta \
 && gcc -o delta/zipadjust OpenDelta/jni/zipadjust.c OpenDelta/jni/zipadjust_run.c -lz \
 && cp OpenDelta/server/minsignapk.jar OpenDelta/server/opendelta.sh delta/ \
 && chmod +x delta/opendelta.sh \
 && rm -rf OpenDelta/

# Create Volumes
################
ENV MIRROR_DIR=/srv/mirror \
    SRC_DIR=/srv/src \
    TMP_DIR=/srv/tmp \
    CCACHE_DIR=/srv/ccache \
    ZIP_DIR=/srv/zips \
    LMANIFEST_DIR=/srv/local_manifests \
    DELTA_DIR=/srv/delta \
    KEYS_DIR=/srv/keys \
    LOGS_DIR=/srv/logs \
    USERSCRIPTS_DIR=/srv/userscripts \
    PREBUILTS_DIR=/srv/prebuilts

VOLUME [ \
  ${MIRROR_DIR} \
  ${SRC_DIR} \
  ${TMP_DIR} \
  ${CCACHE_DIR} \
  ${ZIP_DIR} \
  ${LMANIFEST_DIR} \
  ${DELTA_DIR} \
  ${KEYS_DIR} \
  ${LOGS_DIR} \
  ${USERSCRIPTS_DIR} \
  ${PREBUILTS_DIR} \
]

# Set work directory and entrypoint
###################################
WORKDIR $SRC_DIR
ENTRYPOINT ["bash", "-c", "/entrypoint.sh"]

# Allow redirection of stdout to docker logs
############################################
RUN ln -sf /proc/1/fd/1 /var/log/docker.log

# Create build user and copy required files
###########################################
ENV ANDROID_JACK_VM_ARGS="-Xmx10g -Dfile.encoding=UTF-8 -XX:+TieredCompilation" \
    BUILD_USER=android-build \
    BUILD_USER_ID=1000 \
    BUILD_USER_GID=1000 \
    BUILD_SCRIPTS_PATH=/srv/scripts \
    PATH="/srv/tools/bin:$PATH"

COPY entrypoint.sh /
COPY src/ ${BUILD_SCRIPTS_PATH}

RUN groupadd -g ${BUILD_USER_GID} ${BUILD_USER} \
 && useradd -m -u ${BUILD_USER_ID} -g ${BUILD_USER_GID} ${BUILD_USER} \
 && mkdir -p ${BUILD_SCRIPTS_PATH} \
 && chmod -R 750 ${BUILD_SCRIPTS_PATH} \
 && chown -R ${BUILD_USER}:${BUILD_USER} /srv \
 && echo "android-build ALL = (root) NOPASSWD: /bin/mount" >> /etc/sudoers \
 && echo "android-build ALL = (root) NOPASSWD: /bin/umount" >> /etc/sudoers \
 && echo "android-build ALL = (root) NOPASSWD: /bin/chown" >> /etc/sudoers

# Set container user
####################
USER ${BUILD_USER}
ENV USER=${BUILD_USER}

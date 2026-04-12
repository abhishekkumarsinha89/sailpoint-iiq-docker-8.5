# =============================================================================
# SailPoint IdentityIQ - Tomcat Container
# Base: Official Tomcat 9 with JDK 11
# =============================================================================

ARG TOMCAT_VERSION=9.0-jdk11-openjdk-slim
FROM tomcat:${TOMCAT_VERSION}

ARG IIQ_VERSION=8.5

# Install required tools
RUN apt-get update && apt-get install -y \
    default-mysql-client \
    unzip \
    curl \
    netcat-openbsd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- Tomcat Configuration ---------------------------------------------------

# Copy custom server.xml (URIEncoding=UTF-8, connector tuning)
COPY conf/server.xml /usr/local/tomcat/conf/server.xml

# NOTE: We keep the default Tomcat manager webapp intact so manager.xml works.
#       tomcat-users.xml and manager.xml are NOT copied here — the default
#       Tomcat Manager webapps folder must exist for the descriptor to be valid.
#       For this OOTB IIQ setup we simply leave Tomcat defaults in place.

# --- SailPoint IIQ Deployment -----------------------------------------------
# The MySQL JDBC driver is already bundled inside identityiq.war — no need
# to source it separately. Just unzip once and extract everything needed.
# Expects: ./src/identityiq-<version>.zip (downloaded from Compass)
COPY src/identityiq-${IIQ_VERSION}.zip /tmp/identityiq.zip

RUN cd /tmp && \
    unzip -q identityiq.zip && \
    # Deploy the WAR into Tomcat webapps
    mkdir -p /usr/local/tomcat/webapps/identityiq && \
    cd /usr/local/tomcat/webapps/identityiq && \
    jar -xf /tmp/identityiq.war && \
    chmod +x /usr/local/tomcat/webapps/identityiq/WEB-INF/bin/iiq && \
    # Extract DB scripts for schema initialisation (used by entrypoint.sh)
    mkdir -p /opt/iiq/database && \
    cd /tmp && unzip -q -o identityiq.zip "database/*" -d /opt/iiq/ 2>/dev/null || true && \
    # Clean up
    rm -f /tmp/identityiq.zip /tmp/identityiq.war

# NOTE: We do NOT overwrite iiq.properties here.
# IIQ ships its own iiq.properties inside the WAR with correct Spring bean keys.
# The entrypoint.sh patches only the DB connection values at runtime using sed,
# which avoids the "Invalid key 'datasource'" Spring startup error.

# --- Entrypoint Script -------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create FILE_SHARE directory used by IIQ
RUN mkdir -p /FILE_SHARE

EXPOSE 8080 8000

VOLUME ["/usr/local/tomcat/webapps", "/FILE_SHARE", "/usr/local/tomcat/logs"]

WORKDIR /usr/local/tomcat

ENTRYPOINT ["/entrypoint.sh"]

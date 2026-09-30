FROM hci-pr1107-review:runtime
COPY verify-ptah-schema.sh /verify-ptah-schema.sh
COPY ptah-schema.sql /verify-ptah-schema.sql
COPY ptah-upgrade.sql /verify-ptah-upgrade.sql
COPY ptah-legacy-repairs.sql /verify-ptah-legacy-repairs.sql
COPY legacy_schema.sql legacy_extras.sql legacy_migration_035.sql legacy_init.sql legacy_data_init.sql original_040.sql /
RUN chmod +x /verify-ptah-schema.sh
ENTRYPOINT ["/verify-ptah-schema.sh"]

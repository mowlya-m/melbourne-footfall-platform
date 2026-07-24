###############################################################################
# Bronze catalog table
#
# Registers the Firehose output so Athena can query it. Uses partition
# projection rather than a crawler: partitions follow a strictly predictable
# dt/hour pattern, so Athena can compute them at query time instead of reading
# them from the catalog. That removes the crawler entirely, along with its cost,
# its schedule, and the window where new partitions exist in S3 but not in the
# catalog.
###############################################################################

resource "aws_glue_catalog_table" "bronze_pedestrian" {
  name          = "bronze_pedestrian"
  database_name = aws_glue_catalog_database.main.name
  description   = "Raw sensor readings as delivered by Firehose. Append-only, never modified."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL             = "TRUE"
    "classification"     = "json"
    "compressionType"    = "gzip"
    "projection.enabled" = "true"

    # Partition projection configuration. `dt` is bounded at the lower end by the
    # first delivery and left open at the upper end by NOW, so the table needs no
    # maintenance as time passes.
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "${var.bronze_projection_start_date},NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"

    "projection.hour.type"   = "integer"
    "projection.hour.range"  = "0,23"
    "projection.hour.digits" = "2"

    "storage.location.template" = "s3://${aws_s3_bucket.data.id}/bronze/pedestrian/dt=$${dt}/hour=$${hour}"
  }

  partition_keys {
    name = "dt"
    type = "string"
  }

  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.id}/bronze/pedestrian/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        # Tolerates upstream adding fields without breaking existing queries.
        "ignore.malformed.json" = "true"
        "dots.in.keys"          = "false"
      }
    }

    # Column names and types mirror the producer output exactly. Renaming here
    # would mean a schema change is invisible until a query returns nulls.
    columns {
      name    = "location_id"
      type    = "int"
      comment = "City of Melbourne sensor identifier."
    }

    columns {
      name    = "sensing_datetime"
      type    = "string"
      comment = "Event time in UTC, ISO 8601. Kept as string; cast at query time."
    }

    columns {
      name    = "sensing_date"
      type    = "string"
      comment = "Melbourne local date as published upstream."
    }

    columns {
      name    = "sensing_time"
      type    = "string"
      comment = "Melbourne local time as published upstream, HH:MM."
    }

    columns {
      name    = "direction_1"
      type    = "int"
      comment = "Count in the sensor's first direction."
    }

    columns {
      name    = "direction_2"
      type    = "int"
      comment = "Count in the sensor's second direction."
    }

    columns {
      name    = "total_of_directions"
      type    = "int"
      comment = "Sum of both directions as published upstream."
    }

    columns {
      name    = "dedupe_key"
      type    = "string"
      comment = "Composite natural key: location_id#sensing_datetime."
    }

    columns {
      name    = "ingested_at"
      type    = "string"
      comment = "When the producer read this record. Distinguishes late data from delayed processing."
    }
  }
}

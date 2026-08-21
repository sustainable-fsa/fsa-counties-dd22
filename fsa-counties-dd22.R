# install.packages("pak")
# pak::pak(
#   c("magrittr",
#     "tidyverse",
#     "sf",
#     "tigris",
#     "rmapshaper")
# )

library(magrittr)
library(tidyverse)
library(sf)
library(tigris)
library(rmapshaper)

source("R/s3-archive.R")
s3_preflight()

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "fsa-counties-dd22")

## The FSA county definitions
## Clean and validate
counties <-
  "/vsizip/FSA_Counties_dd22_NonGeneralized.gdb.zip" %>%
  {
    tmp <- tempfile(fileext = ".gpkg")
    sf::gdal_utils(
      util = "vectortranslate",
      source = .,
      destination = tmp,
      options = c("-nlt", "CONVERT_TO_LINEAR", "-nlt", "MULTIPOLYGON")
    )
    sf::read_sf(tmp)
  } %>%
  dplyr::mutate(id = paste0(FSA_STCOU, "-", FIPS_C)) %>%
  dplyr::select(id) %>%
  sf::st_transform("WGS84") %>%
  dplyr::group_by(id) %>%
  dplyr::summarise() %>%
  sf::st_cast("MULTIPOLYGON") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  sf::st_make_valid() %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  sf::st_make_valid() %>%
  sf::st_transform("WGS84") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  sf::st_cast("MULTIPOLYGON") %>%
  dplyr::arrange(id)

## Drop holes
unlink("fsa-counties-dd22.geojson")
counties %>%
  sf::write_sf("fsa-counties-dd22.geojson",
               delete_dsn = TRUE)

out <- rmapshaper::apply_mapshaper_commands("fsa-counties-dd22.geojson", 
                                            command = "-clean gap-fill-area=500",
                                            sys = TRUE,
                                            sys_mem = 16)
counties <- 
  sf::read_sf(out) %>%
  dplyr::left_join(
    sf::read_sf("/vsizip/FSA_Counties_dd22_NonGeneralized.gdb.zip") %>%
      sf::st_drop_geometry() %>%
      dplyr::mutate(id = paste0(FSA_STCOU, "-", FIPS_C)) %>%
      dplyr::arrange(id) %>%
      dplyr::distinct(id, .keep_all = TRUE)
  ) %>%
  dplyr::select((!id))

unlink("fsa-counties-dd22.geojson")

## Create a parquet version
counties |>
  sf::write_sf(
    "fsa-counties-dd22.parquet",
    driver = "Parquet",
    layer_options = c("COMPRESSION=ZSTD",
                      "COMPRESSION_LEVEL=13"),
    delete_dsn = TRUE
  )

## Create a simplified version
counties %>%
  dplyr::filter(!(FIPSST %in% c("60", "78", "14", "52", "69", "66"))) %>%
  dplyr::select(id = FSA_STCOU) %>%
  rmapshaper::ms_simplify(keep = 0.008,
                          keep_shapes = TRUE,
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_clip(
    clip =
      tigris::counties(cb = TRUE,
                       resolution = "5m") %>%
      sf::st_transform("WGS84") %>%
      rmapshaper::ms_explode(sys = TRUE,
                             sys_mem = 16) %>%
      rmapshaper::ms_dissolve(sys = TRUE,
                              sys_mem = 16),
    remove_slivers = TRUE,
    sys = TRUE,
    sys_mem = 16
  ) %>%
  sf::st_make_valid() %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  tigris::shift_geometry() %>%
  sf::st_make_valid() %>%
  sf::st_transform("WGS84") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  sf::st_cast("MULTIPOLYGON") %>%  
  sf::st_make_valid() %>%
  sf::st_transform("WGS84") %>%
  rmapshaper::ms_explode(sys = TRUE,
                         sys_mem = 16) %>%
  rmapshaper::ms_dissolve(field = "id",
                          sys = TRUE,
                          sys_mem = 16) %>%
  sf::st_cast("MULTIPOLYGON") %>%
  dplyr::arrange(id) %>%
  dplyr::left_join(
    sf::read_sf("fsa-counties-dd22.parquet") %>%
      sf::st_drop_geometry() %>%
      dplyr::select(id = FSA_STCOU,
                    state = STATENAME,
                    county = FSA_Name) %>%
      dplyr::distinct()
  ) %T>%
  sf::write_sf("fsa-counties-dd22.geojson",
               delete_dsn = TRUE)

system(
  "
mapshaper \\
  fsa-counties-dd22.geojson \\
  -clean rewind \\
  -rename-layers counties \\
  -dissolve field=state copy-fields='id' + name=states \\
  -each 'id=id.slice(0,2)' target=states \\
  -clean target=counties,states \\
  -rename-layers counties,states target=counties,states \\
  -o format=topojson quantization=1e6 fix-geometry id-field='id' bbox target=* fsa-counties-dd22.topojson
"
)

unlink("fsa-counties-dd22.geojson")

# sf::read_sf("fsa-counties-dd22.topojson", layer = "counties") %>%
#   mapview::mapview()

# Knit the readme
rmarkdown::render("README.Rmd")

## Publish the archive to S3 (dual-write alongside the git mirror)
s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/FSA_Counties_dd22_NonGeneralized.gdb.zip"),
       file = "FSA_Counties_dd22_NonGeneralized.gdb.zip",
       content_type = "application/zip")

s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/fsa-counties-dd22.topojson"),
       file = "fsa-counties-dd22.topojson",
       ## TopoJSON is JSON. Without this, s3_put() falls back to
       ## application/octet-stream, which CloudFront will not compress: the CDN
       ## copy went out at 1,355,656 bytes where the gzipped GitHub Pages copy
       ## of the same file is 451,897.
       content_type = "application/json")

s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/fsa-counties-dd22.parquet"),
       file = "fsa-counties-dd22.parquet",
       content_type = "application/vnd.apache.parquet")

s3_push(bucket = s3_bucket,
        prefix = paste0(s3_prefix, "/foia"),
        local_dir = "foia",
        delete = TRUE)

s3_write_manifest(bucket = s3_bucket,
                  prefix = s3_prefix)

cf_invalidate(
  paths = c(
    paste0("/", s3_prefix, "/FSA_Counties_dd22_NonGeneralized.gdb.zip"),
    paste0("/", s3_prefix, "/fsa-counties-dd22.topojson"),
    paste0("/", s3_prefix, "/fsa-counties-dd22.parquet"),
    paste0("/", s3_prefix, "/_manifest.txt")
  )
)

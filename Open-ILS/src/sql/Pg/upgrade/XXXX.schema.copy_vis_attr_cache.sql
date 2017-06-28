BEGIN;

-- Thist change drops a needless join and saves 10-15% in time cost
CREATE OR REPLACE FUNCTION search.facets_for_record_set(ignore_facet_classes text[], hits bigint[]) RETURNS TABLE(id integer, value text, count bigint)
AS $f$
    SELECT id, value, count
      FROM (
        SELECT  mfae.field AS id,
                mfae.value,
                COUNT(DISTINCT mfae.source),
                row_number() OVER (
                    PARTITION BY mfae.field ORDER BY COUNT(DISTINCT mfae.source) DESC
                ) AS rownum
          FROM  metabib.facet_entry mfae
                JOIN config.metabib_field cmf ON (cmf.id = mfae.field)
          WHERE mfae.source = ANY ($2)
                AND cmf.facet_field
                AND cmf.field_class NOT IN (SELECT * FROM unnest($1))
          GROUP by 1, 2
      ) all_facets
      WHERE rownum <= (
        SELECT COALESCE(
            (SELECT value::INT FROM config.global_flag WHERE name = 'search.max_facets_per_field' AND enabled),
            1000
        )
      );
$f$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION unapi.metabib_virtual_record_feed ( id_list BIGINT[], format TEXT, includes TEXT[], org TEXT, depth INT DEFAULT NULL, slimit HSTORE DEFAULT NULL, soffset HSTORE DEFAULT NULL, include_xmlns BOOL DEFAULT TRUE, title TEXT DEFAULT NULL, description TEXT DEFAULT NULL, creator TEXT DEFAULT NULL, update_ts TEXT DEFAULT NULL, unapi_url TEXT DEFAULT NULL, header_xml XML DEFAULT NULL ) RETURNS XML AS $F$
DECLARE
    layout          unapi.bre_output_layout%ROWTYPE;
    transform       config.xml_transform%ROWTYPE;
    item_format     TEXT;
    tmp_xml         TEXT;
    xmlns_uri       TEXT := 'http://open-ils.org/spec/feed-xml/v1';
    ouid            INT;
    element_list    TEXT[];
BEGIN

    IF org = '-' OR org IS NULL THEN
        SELECT shortname INTO org FROM evergreen.org_top();
    END IF;

    SELECT id INTO ouid FROM actor.org_unit WHERE shortname = org;
    SELECT * INTO layout FROM unapi.bre_output_layout WHERE name = format;

    IF layout.name IS NULL THEN
        RETURN NULL::XML;
    END IF;

    SELECT * INTO transform FROM config.xml_transform WHERE name = layout.transform;
    xmlns_uri := COALESCE(transform.namespace_uri,xmlns_uri);

    -- Gather the bib xml
    SELECT XMLAGG( unapi.mmr(i, format, '', includes, org, depth, slimit, soffset, include_xmlns)) INTO tmp_xml FROM UNNEST( id_list ) i;

    IF layout.title_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.title_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, title;
    END IF;

    IF layout.description_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.description_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, description;
    END IF;

    IF layout.creator_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.creator_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, creator;
    END IF;

    IF layout.update_ts_element IS NOT NULL THEN
        EXECUTE 'SELECT XMLCONCAT( XMLELEMENT( name '|| layout.update_ts_element ||', XMLATTRIBUTES( $1 AS xmlns), $3), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML, update_ts;
    END IF;

    IF unapi_url IS NOT NULL THEN
        EXECUTE $$SELECT XMLCONCAT( XMLELEMENT( name link, XMLATTRIBUTES( 'http://www.w3.org/1999/xhtml' AS xmlns, 'unapi-server' AS rel, $1 AS href, 'unapi' AS title)), $2)$$ INTO tmp_xml USING unapi_url, tmp_xml::XML;
    END IF;

    IF header_xml IS NOT NULL THEN tmp_xml := XMLCONCAT(header_xml,tmp_xml::XML); END IF;

    element_list := regexp_split_to_array(layout.feed_top,E'\\.');
    FOR i IN REVERSE ARRAY_UPPER(element_list, 1) .. 1 LOOP
        EXECUTE 'SELECT XMLELEMENT( name '|| quote_ident(element_list[i]) ||', XMLATTRIBUTES( $1 AS xmlns), $2)' INTO tmp_xml USING xmlns_uri, tmp_xml::XML;
    END LOOP;

    RETURN tmp_xml::XML;
END;
$F$ LANGUAGE PLPGSQL STABLE;

CREATE TABLE asset.copy_vis_attr_cache (
    id              BIGSERIAL   PRIMARY KEY,
    record          BIGINT      NOT NULL, -- No FKEYs, managed by user triggers.
    target_copy     BIGINT      NOT NULL,
    vis_attr_vector INT[]
);
CREATE INDEX copy_vis_attr_cache_record_idx ON asset.copy_vis_attr_cache (record);
CREATE INDEX copy_vis_attr_cache_copy_idx ON asset.copy_vis_attr_cache (target_copy);

ALTER TABLE biblio.record_entry ADD COLUMN vis_attr_vector INT[];

CREATE OR REPLACE FUNCTION search.calculate_visibility_attribute ( value INT, attr TEXT ) RETURNS INT AS $f$
SELECT  ((CASE $2

            WHEN 'luri_org'         THEN 0 -- "b" attr
            WHEN 'bib_source'       THEN 1 -- "b" attr

            WHEN 'copy_flags'       THEN 0 -- "c" attr
            WHEN 'owning_lib'       THEN 1 -- "c" attr
            WHEN 'circ_lib'         THEN 2 -- "c" attr
            WHEN 'status'           THEN 3 -- "c" attr
            WHEN 'location'         THEN 4 -- "c" attr
            WHEN 'location_group'   THEN 5 -- "c" attr

        END) << 28 ) | $1;

/* copy_flags bit positions, LSB-first:

 0: asset.copy.opac_visible


   When adding flags, you must update asset.all_visible_flags()

   Because bib and copy values are stored separately, we can reuse
   shifts, saving us some space. We could probably take back a bit
   too, but I'm not sure its worth squeezing that last one out. We'd
   be left with just 2 slots for copy attrs, rather than 10.
*/

$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION search.calculate_visibility_attribute_list ( attr TEXT, value INT[] ) RETURNS INT[] AS $f$
    SELECT ARRAY_AGG(search.calculate_visibility_attribute(x, $1)) FROM UNNEST($2) AS X;
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION search.calculate_visibility_attribute_test ( attr TEXT, value INT[], negate BOOL DEFAULT FALSE ) RETURNS TEXT AS $f$
    SELECT  CASE WHEN $3 THEN '!' ELSE '' END || '(' || ARRAY_TO_STRING(search.calculate_visibility_attribute_list($1,$2),'|') || ')';
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION asset.calculate_copy_visibility_attribute_set ( copy_id BIGINT ) RETURNS INT[] AS $f$
DECLARE
    copy_row    asset.copy%ROWTYPE;
    lgroup_map  asset.copy_location_group_map%ROWTYPE;
    attr_set    INT[];
BEGIN
    SELECT * INTO copy_row FROM asset.copy WHERE id = copy_id;

    attr_set := attr_set || search.calculate_visibility_attribute(copy_row.opac_visible::INT, 'copy_flags');
    attr_set := attr_set || search.calculate_visibility_attribute(copy_row.circ_lib, 'circ_lib');
    attr_set := attr_set || search.calculate_visibility_attribute(copy_row.status, 'status');
    attr_set := attr_set || search.calculate_visibility_attribute(copy_row.location, 'location');

    SELECT  ARRAY_APPEND(
                attr_set,
                search.calculate_visibility_attribute(owning_lib, 'owning_lib')
            ) INTO attr_set
      FROM  asset.call_number
      WHERE id = copy_row.call_number;

    FOR lgroup_map IN SELECT * FROM asset.copy_location_group_map WHERE location = copy_row.location LOOP
        attr_set := attr_set || search.calculate_visibility_attribute(lgroup_map.lgroup, 'location_group');
    END LOOP;

    RETURN attr_set;
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION biblio.calculate_bib_visibility_attribute_set ( bib_id BIGINT ) RETURNS INT[] AS $f$
DECLARE
    bib_row     biblio.record_entry%ROWTYPE;
    cn_row      asset.call_number%ROWTYPE;
    attr_set    INT[];
BEGIN
    SELECT * INTO bib_row FROM biblio.record_entry WHERE id = bib_id;

    IF bib_row.source IS NOT NULL THEN
        attr_set := attr_set || search.calculate_visibility_attribute(bib_row.source, 'bib_source');
    END IF;

    FOR cn_row IN
        SELECT  cn.*
          FROM  asset.call_number cn
                JOIN asset.uri_call_number_map m ON (cn.id = m.call_number)
                JOIN asset.uri u ON (u.id = m.uri)
          WHERE cn.record = bib_id
                AND cn.label = '##URI##'
                AND u.active
    LOOP
        attr_set := attr_set || search.calculate_visibility_attribute(cn_row.owning_lib, 'luri_org');
    END LOOP;

    RETURN attr_set;
END;
$f$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION asset.cache_copy_visibility () RETURNS TRIGGER as $func$
DECLARE
    ocn     asset.call_number%ROWTYPE;
    ncn     asset.call_number%ROWTYPE;
    cid     BIGINT;
BEGIN

    IF TG_TABLE_NAME = 'peer_bib_copy_map' THEN -- Only needs ON INSERT OR DELETE, so handle separately
        IF TG_OP = 'INSERT' THEN
            INSERT INTO asset.copy_vis_attr_cache (record, target_copy, vis_attr_vector) VALUES (
                NEW.peer_record,
                NEW.target_copy,
                asset.calculate_copy_visibility_attribute_set(NEW.target_copy)
            );

            RETURN NEW;
        ELSIF TG_OP = 'DELETE' THEN
            DELETE FROM asset.copy_vis_attr_cache
              WHERE record = NEW.peer_record AND target_copy = NEW.target_copy;

            RETURN OLD;
        END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN -- Handles ON INSERT. ON UPDATE is below.
        IF TG_TABLE_NAME IN ('copy', 'unit') THEN
            SELECT * INTO ncn FROM asset.call_number cn WHERE id = NEW.call_number;
            INSERT INTO asset.copy_vis_attr_cache (record, target_copy, vis_attr_vector) VALUES (
                ncn.record,
                NEW.target_copy,
                asset.calculate_copy_visibility_attribute_set(NEW.id)
            );
        ELSIF TG_TABLE_NAME = 'record_entry' THEN
            NEW.vis_attr_vector := biblio.calculate_bib_visibility_attribute_set(NEW.id);
        END IF;

        RETURN NEW;
    END IF;

    -- handle items first, since with circulation activity
    -- their statuses change frequently
    IF TG_TABLE_NAME IN ('copy', 'unit') THEN -- This handles ON UPDATE OR DELETE. ON INSERT above

        IF TG_OP = 'DELETE' THEN -- Shouldn't get here, normally
            DELETE FROM asset.copy_vis_attr_cache WHERE target_copy = OLD.id;
            RETURN OLD;
        END IF;

        SELECT * INTO ncn FROM asset.call_number cn WHERE id = NEW.call_number;

        IF OLD.deleted <> NEW.deleted THEN
            IF NEW.deleted THEN
                DELETE FROM asset.copy_vis_attr_cache WHERE target_copy = OLD.id;
            ELSE
                INSERT INTO asset.copy_vis_attr_cache (record, target_copy, vis_attr_vector) VALUES (
                    ncn.record,
                    NEW.id,
                    asset.calculate_copy_visibility_attribute_set(NEW.id)
                );
            END IF;

            RETURN NEW;
        ELSIF OLD.call_number  <> NEW.call_number THEN
            SELECT * INTO ocn FROM asset.call_number cn WHERE id = OLD.call_number;

            IF ncn.record <> ocn.record THEN
                UPDATE  biblio.record_entry
                  SET   vis_attr_vector = biblio.calculate_bib_visibility_attribute_set(ncn.record)
                  WHERE id = ocn.record;
            END IF;
        END IF;

        IF OLD.location     <> NEW.location OR
           OLD.status       <> NEW.status OR
           OLD.opac_visible <> NEW.opac_visible OR
           OLD.circ_lib     <> NEW.circ_lib
        THEN
            -- any of these could change visibility, but
            -- we'll save some queries and not try to calculate
            -- the change directly
            UPDATE  asset.copy_vis_attr_cache
              SET   target_copy = NEW.id,
                    vis_attr_vector = asset.calculate_copy_visibility_attribute_set(NEW.id)
              WHERE target_copy = OLD.id;

        END IF;

    ELSIF TG_TABLE_NAME = 'call_number' THEN -- Only ON UPDATE. Copy handler will deal with ON INSERT OR DELETE.

        IF OLD.record <> NEW.record THEN
            IF NEW.label = '##URI##' THEN
                UPDATE  biblio.record_entry
                  SET   vis_attr_vector = biblio.calculate_bib_visibility_attribute_set(OLD.record)
                  WHERE id = OLD.record;

                UPDATE  biblio.record_entry
                  SET   vis_attr_vector = biblio.calculate_bib_visibility_attribute_set(NEW.record)
                  WHERE id = NEW.record;
            END IF;

            UPDATE  asset.copy_vis_attr_cache
              SET   record = NEW.record,
                    vis_attr_vector = asset.calculate_copy_visibility_attribute_set(target_copy)
              WHERE target_copy IN (SELECT id FROM asset.copy WHERE call_number = NEW.id)
                    AND record = OLD.record;

        ELSIF OLD.owning_lib <> NEW.owning_lib THEN
            UPDATE  asset.copy_vis_attr_cache
              SET   vis_attr_vector = asset.calculate_copy_visibility_attribute_set(target_copy)
              WHERE target_copy IN (SELECT id FROM asset.copy WHERE call_number = NEW.id)
                    AND record = NEW.record;

            IF NEW.label = '##URI##' THEN
                UPDATE  biblio.record_entry
                  SET   vis_attr_vector = biblio.calculate_bib_visibility_attribute_set(OLD.record)
                  WHERE id = OLD.record;
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'record_entry' THEN -- Only handles ON UPDATE OR DELETE

        IF TG_OP = 'DELETE' THEN -- Shouldn't get here, normally
            DELETE FROM asset.copy_vis_attr_cache WHERE record = OLD.id;
            RETURN OLD;
        ELSIF OLD.source <> NEW.source THEN
            NEW.vis_attr_vector := biblio.calculate_bib_visibility_attribute_set(NEW.id);
        END IF;

    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE PLPGSQL;


-- Helper functions for use in constructing searches --

CREATE OR REPLACE FUNCTION asset.all_visible_flags () RETURNS TEXT AS $f$
    SELECT  '(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(1 << x, 'copy_flags')),'&') || ')'
      FROM  GENERATE_SERIES(0,0) AS x; -- increment as new flags are added.
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.visible_orgs (otype TEXT) RETURNS TEXT AS $f$
    SELECT  '(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, $1)),'|') || ')'
      FROM  actor.org_unit
      WHERE opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.invisible_orgs (otype TEXT) RETURNS TEXT AS $f$
    SELECT  '!(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, $1)),'|') || ')'
      FROM  actor.org_unit
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

-- Bib-oriented defaults for search
CREATE OR REPLACE FUNCTION asset.bib_source_default () RETURNS TEXT AS $f$
    SELECT  '(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, 'bib_source')),'|') || ')'
      FROM  config.bib_source
      WHERE transcendant;
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION asset.luri_org_default () RETURNS TEXT AS $f$
    SELECT  * FROM asset.invisible_orgs('luri_org');
$f$ LANGUAGE SQL STABLE;

-- Copy-oriented defaults for search
CREATE OR REPLACE FUNCTION asset.location_group_default () RETURNS TEXT AS $f$
    SELECT  '!(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, 'location_group')),'|') || ')'
      FROM  asset.copy_location_group
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.location_default () RETURNS TEXT AS $f$
    SELECT  '!(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, 'location')),'|') || ')'
      FROM  asset.copy_location
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.status_default () RETURNS TEXT AS $f$
    SELECT  '!(' || ARRAY_TO_STRING(ARRAY_AGG(search.calculate_visibility_attribute(id, 'status')),'|') || ')'
      FROM  config.copy_status
      WHERE NOT opac_visible;
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.owning_lib_default () RETURNS TEXT AS $f$
    SELECT  * FROM asset.invisible_orgs('owning_lib');
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.circ_lib_default () RETURNS TEXT AS $f$
    SELECT  * FROM asset.invisible_orgs('circ_lib');
$f$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION asset.patron_default_visibility_mask () RETURNS TABLE (b_attrs TEXT, c_attrs TEXT)  AS $f$
DECLARE
    copy_flags      TEXT; -- "c" attr

    owning_lib      TEXT; -- "c" attr
    circ_lib        TEXT; -- "c" attr
    status          TEXT; -- "c" attr
    location        TEXT; -- "c" attr
    location_group  TEXT; -- "c" attr

    luri_org        TEXT; -- "b" attr
    bib_sources     TEXT; -- "b" attr
BEGIN
    copy_flags      := asset.all_visible_flags(); -- Will always have at least one

    owning_lib      := NULLIF(asset.owning_lib_default(),'!()');
    
    circ_lib        := NULLIF(asset.circ_lib_default(),'!()');
    status          := NULLIF(asset.status_default(),'!()');
    location        := NULLIF(asset.location_default(),'!()');
    location_group  := NULLIF(asset.location_group_default(),'!()');

    luri_org        := NULLIF(asset.luri_org_default(),'!()');
    bib_sources     := NULLIF(asset.bib_source_default(),'()');

    RETURN QUERY SELECT
        '('||ARRAY_TO_STRING(
            ARRAY[luri_org,bib_sources],
            '|'
        )||')',
        '('||ARRAY_TO_STRING(
            ARRAY[copy_flags,owning_lib,circ_lib,status,location,location_group]::TEXT[],
            '&'
        )||')';
END;
$f$ LANGUAGE PLPGSQL STABLE ROWS 1;

CREATE OR REPLACE FUNCTION metabib.suggest_browse_entries(raw_query_text text, search_class text, headline_opts text, visibility_org integer, query_limit integer, normalization integer)
 RETURNS TABLE(value text, field integer, buoyant_and_class_match boolean, field_match boolean, field_weight integer, rank real, buoyant boolean, match text)
AS $f$
DECLARE
    prepared_query_texts    TEXT[];
    query                   TSQUERY;
    plain_query             TSQUERY;
    opac_visibility_join    TEXT;
    search_class_join       TEXT;
    r_fields                RECORD;
BEGIN
    prepared_query_texts := metabib.autosuggest_prepare_tsquery(raw_query_text);

    query := TO_TSQUERY('keyword', prepared_query_texts[1]);
    plain_query := TO_TSQUERY('keyword', prepared_query_texts[2]);

    visibility_org := NULLIF(visibility_org,-1);
    IF visibility_org IS NOT NULL THEN
        opac_visibility_join := '
    JOIN asset.copy_vis_attr_cache acvac ON (acvac.record = x.source)
    JOIN vm ON (acvac.vis_attr_vector @@ vm.c_attrs::query_int)
';
    ELSE
        opac_visibility_join := '';
    END IF;

    -- The following determines whether we only provide suggestsons matching
    -- the user's selected search_class, or whether we show other suggestions
    -- too. The reason for MIN() is that for search_classes like
    -- 'title|proper|uniform' you would otherwise get multiple rows.  The
    -- implication is that if title as a class doesn't have restrict,
    -- nor does the proper field, but the uniform field does, you're going
    -- to get 'false' for your overall evaluation of 'should we restrict?'
    -- To invert that, change from MIN() to MAX().

    SELECT
        INTO r_fields
            MIN(cmc.restrict::INT) AS restrict_class,
            MIN(cmf.restrict::INT) AS restrict_field
        FROM metabib.search_class_to_registered_components(search_class)
            AS _registered (field_class TEXT, field INT)
        JOIN
            config.metabib_class cmc ON (cmc.name = _registered.field_class)
        LEFT JOIN
            config.metabib_field cmf ON (cmf.id = _registered.field);

    -- evaluate 'should we restrict?'
    IF r_fields.restrict_field::BOOL OR r_fields.restrict_class::BOOL THEN
        search_class_join := '
    JOIN
        metabib.search_class_to_registered_components($2)
        AS _registered (field_class TEXT, field INT) ON (
            (_registered.field IS NULL AND
                _registered.field_class = cmf.field_class) OR
            (_registered.field = cmf.id)
        )
    ';
    ELSE
        search_class_join := '
    LEFT JOIN
        metabib.search_class_to_registered_components($2)
        AS _registered (field_class TEXT, field INT) ON (
            _registered.field_class = cmc.name
        )
    ';
    END IF;

    RETURN QUERY EXECUTE '
WITH vm AS ( SELECT * FROM asset.patron_default_visibility_mask() ),
     mbe AS (SELECT * FROM metabib.browse_entry WHERE index_vector @@ $1 LIMIT 10000)
SELECT  DISTINCT
        x.value,
        x.id,
        x.push,
        x.restrict,
        x.weight,
        x.ts_rank_cd,
        x.buoyant,
        TS_HEADLINE(value, $7, $3)
  FROM  (SELECT DISTINCT
                mbe.value,
                cmf.id,
                cmc.buoyant AND _registered.field_class IS NOT NULL AS push,
                _registered.field = cmf.id AS restrict,
                cmf.weight,
                TS_RANK_CD(mbe.index_vector, $1, $6),
                cmc.buoyant,
                mbedm.source
          FROM  metabib.browse_entry_def_map mbedm
                JOIN mbe ON (mbe.id = mbedm.entry)
                JOIN config.metabib_field cmf ON (cmf.id = mbedm.def)
                JOIN config.metabib_class cmc ON (cmf.field_class = cmc.name)
                '  || search_class_join || '
          ORDER BY 3 DESC, 4 DESC NULLS LAST, 5 DESC, 6 DESC, 7 DESC, 1 ASC
          LIMIT 1000) AS x
        ' || opac_visibility_join || '
  ORDER BY 3 DESC, 4 DESC NULLS LAST, 5 DESC, 6 DESC, 7 DESC, 1 ASC
  LIMIT $5
'   -- sic, repeat the order by clause in the outer select too
    USING
        query, search_class, headline_opts,
        visibility_org, query_limit, normalization, plain_query
        ;

    -- sort order:
    --  buoyant AND chosen class = match class
    --  chosen field = match field
    --  field weight
    --  rank
    --  buoyancy
    --  value itself

END;
$f$ LANGUAGE plpgsql ROWS 10;

CREATE OR REPLACE FUNCTION metabib.browse(search_field integer[], browse_term text, context_org integer DEFAULT NULL::integer, context_loc_group integer DEFAULT NULL::integer, staff boolean DEFAULT false, pivot_id bigint DEFAULT NULL::bigint, result_limit integer DEFAULT 10)
 RETURNS SETOF metabib.flat_browse_entry_appearance
AS $f$
DECLARE
    core_query              TEXT;
    back_query              TEXT;
    forward_query           TEXT;
    pivot_sort_value        TEXT;
    pivot_sort_fallback     TEXT;
    context_locations       INT[];
    browse_superpage_size   INT;
    results_skipped         INT := 0;
    back_limit              INT;
    back_to_pivot           INT;
    forward_limit           INT;
    forward_to_pivot        INT;
BEGIN
    -- First, find the pivot if we were given a browse term but not a pivot.
    IF pivot_id IS NULL THEN
        pivot_id := metabib.browse_pivot(search_field, browse_term);
    END IF;

    SELECT INTO pivot_sort_value, pivot_sort_fallback
        sort_value, value FROM metabib.browse_entry WHERE id = pivot_id;

    -- Bail if we couldn't find a pivot.
    IF pivot_sort_value IS NULL THEN
        RETURN;
    END IF;

    -- Transform the context_loc_group argument (if any) (logc at the
    -- TPAC layer) into a form we'll be able to use.
    IF context_loc_group IS NOT NULL THEN
        SELECT INTO context_locations ARRAY_AGG(location)
            FROM asset.copy_location_group_map
            WHERE lgroup = context_loc_group;
    END IF;

    -- Get the configured size of browse superpages.
    SELECT INTO browse_superpage_size COALESCE(value::INT,100)     -- NULL ok
        FROM config.global_flag
        WHERE enabled AND name = 'opac.browse.holdings_visibility_test_limit';

    -- First we're going to search backward from the pivot, then we're going
    -- to search forward.  In each direction, we need two limits.  At the
    -- lesser of the two limits, we delineate the edge of the result set
    -- we're going to return.  At the greater of the two limits, we find the
    -- pivot value that would represent an offset from the current pivot
    -- at a distance of one "page" in either direction, where a "page" is a
    -- result set of the size specified in the "result_limit" argument.
    --
    -- The two limits in each direction make four derived values in total,
    -- and we calculate them now.
    back_limit := CEIL(result_limit::FLOAT / 2);
    back_to_pivot := result_limit;
    forward_limit := result_limit / 2;
    forward_to_pivot := result_limit - 1;

    -- This is the meat of the SQL query that finds browse entries.  We'll
    -- pass this to a function which uses it with a cursor, so that individual
    -- rows may be fetched in a loop until some condition is satisfied, without
    -- waiting for a result set of fixed size to be collected all at once.
    core_query := '
SELECT  mbe.id,
        mbe.value,
        mbe.sort_value
  FROM  metabib.browse_entry mbe
  WHERE (
            EXISTS ( -- are there any bibs using this mbe via the requested fields?
                SELECT  1
                  FROM  metabib.browse_entry_def_map mbedm
                  WHERE mbedm.entry = mbe.id AND mbedm.def = ANY(' || quote_literal(search_field) || ')
            ) OR EXISTS ( -- are there any authorities using this mbe via the requested fields?
                SELECT  1
                  FROM  metabib.browse_entry_simple_heading_map mbeshm
                        JOIN authority.simple_heading ash ON ( mbeshm.simple_heading = ash.id )
                        JOIN authority.control_set_auth_field_metabib_field_map_refs map ON (
                            ash.atag = map.authority_field
                            AND map.metabib_field = ANY(' || quote_literal(search_field) || ')
                        )
                  WHERE mbeshm.entry = mbe.id
            )
        ) AND ';

    -- This is the variant of the query for browsing backward.
    back_query := core_query ||
        ' mbe.sort_value <= ' || quote_literal(pivot_sort_value) ||
    ' ORDER BY mbe.sort_value DESC, mbe.value DESC LIMIT 1000';

    -- This variant browses forward.
    forward_query := core_query ||
        ' mbe.sort_value > ' || quote_literal(pivot_sort_value) ||
    ' ORDER BY mbe.sort_value, mbe.value LIMIT 1000';

    -- We now call the function which applies a cursor to the provided
    -- queries, stopping at the appropriate limits and also giving us
    -- the next page's pivot.
    RETURN QUERY
        SELECT * FROM metabib.staged_browse(
            back_query, search_field, context_org, context_locations,
            staff, browse_superpage_size, TRUE, back_limit, back_to_pivot
        ) UNION
        SELECT * FROM metabib.staged_browse(
            forward_query, search_field, context_org, context_locations,
            staff, browse_superpage_size, FALSE, forward_limit, forward_to_pivot
        ) ORDER BY row_number DESC;

END;
$f$ LANGUAGE plpgsql ROWS 10;

CREATE OR REPLACE FUNCTION metabib.staged_browse(query text, fields integer[], context_org integer, context_locations integer[], staff boolean, browse_superpage_size integer, count_up_from_zero boolean, result_limit integer, next_pivot_pos integer)
 RETURNS SETOF metabib.flat_browse_entry_appearance
AS $f$
DECLARE
    curs                    REFCURSOR;
    rec                     RECORD;
    qpfts_query             TEXT;
    aqpfts_query            TEXT;
    afields                 INT[];
    bfields                 INT[];
    result_row              metabib.flat_browse_entry_appearance%ROWTYPE;
    results_skipped         INT := 0;
    row_counter             INT := 0;
    row_number              INT;
    slice_start             INT;
    slice_end               INT;
    full_end                INT;
    all_records             BIGINT[];
    all_brecords             BIGINT[];
    all_arecords            BIGINT[];
    superpage_of_records    BIGINT[];
    superpage_size          INT;
    c_tests                 TEXT := '';
    b_tests                 TEXT := '';
    c_orgs                  INT[];
BEGIN
    IF count_up_from_zero THEN
        row_number := 0;
    ELSE
        row_number := -1;
    END IF;

    IF NOT staff THEN
        SELECT x.c_attrs, x.b_attrs INTO c_tests, b_tests FROM asset.patron_default_visibility_mask() x;
    END IF;

    IF c_tests <> '' THEN c_tests := c_tests || '&'; END IF;
    IF b_tests <> '' THEN b_tests := b_tests || '&'; END IF;

    SELECT ARRAY_AGG(id) INTO c_orgs FROM actor.org_unit_descendants(context_org);
    
    c_tests := c_tests || search.calculate_visibility_attribute_test('circ_lib',c_orgs)
               || '&' || search.calculate_visibility_attribute_test('owning_lib',c_orgs);
    
    PERFORM 1 FROM config.internal_flag WHERE enabled AND name = 'opac.located_uri.act_as_copy';
    IF FOUND THEN
        b_tests := b_tests || search.calculate_visibility_attribute_test(
            'luri_org',
            (SELECT ARRAY_AGG(id) FROM actor.org_unit_full_path(context_org) x)
        );
    ELSE
        b_tests := b_tests || search.calculate_visibility_attribute_test(
            'luri_org',
            (SELECT ARRAY_AGG(id) FROM actor.org_unit_ancestors(context_org) x)
        );
    END IF;

    IF context_locations THEN
        IF c_tests <> '' THEN c_tests := c_tests || '&'; END IF;
        c_tests := c_tests || search.calculate_visibility_attribute_test('location',context_locations);
    END IF;

    OPEN curs NO SCROLL FOR EXECUTE query;

    LOOP
        FETCH curs INTO rec;
        IF NOT FOUND THEN
            IF result_row.pivot_point IS NOT NULL THEN
                RETURN NEXT result_row;
            END IF;
            RETURN;
        END IF;

        -- Gather aggregate data based on the MBE row we're looking at now, authority axis
        SELECT INTO all_arecords, result_row.sees, afields
                ARRAY_AGG(DISTINCT abl.bib), -- bibs to check for visibility
                STRING_AGG(DISTINCT aal.source::TEXT, $$,$$), -- authority record ids
                ARRAY_AGG(DISTINCT map.metabib_field) -- authority-tag-linked CMF rows

          FROM  metabib.browse_entry_simple_heading_map mbeshm
                JOIN authority.simple_heading ash ON ( mbeshm.simple_heading = ash.id )
                JOIN authority.authority_linking aal ON ( ash.record = aal.source )
                JOIN authority.bib_linking abl ON ( aal.target = abl.authority )
                JOIN authority.control_set_auth_field_metabib_field_map_refs map ON (
                    ash.atag = map.authority_field
                    AND map.metabib_field = ANY(fields)
                )
          WHERE mbeshm.entry = rec.id;

        -- Gather aggregate data based on the MBE row we're looking at now, bib axis
        SELECT INTO all_brecords, result_row.authorities, bfields
                ARRAY_AGG(DISTINCT source),
                STRING_AGG(DISTINCT authority::TEXT, $$,$$),
                ARRAY_AGG(DISTINCT def)
          FROM  metabib.browse_entry_def_map
          WHERE entry = rec.id
                AND def = ANY(fields);

        SELECT INTO result_row.fields STRING_AGG(DISTINCT x::TEXT, $$,$$) FROM UNNEST(afields || bfields) x;

        result_row.sources := 0;
        result_row.asources := 0;

        -- Bib-linked vis checking
        IF ARRAY_UPPER(all_brecords,1) IS NOT NULL THEN

            SELECT  INTO result_row.sources COUNT(DISTINCT b.id)
              FROM  biblio.record_entry b
                    JOIN asset.copy_vis_attr_cache acvac ON (acvac.record = b.id)
              WHERE b.id = ANY(all_brecords[1:browse_superpage_size])
                    AND (
                        acvac.vis_attr_vector @@ c_tests::query_int
                        OR b.vis_attr_vector @@ b_tests::query_int
                    );

            result_row.accurate := TRUE;

        END IF;

        -- Authority-linked vis checking
        IF ARRAY_UPPER(all_arecords,1) IS NOT NULL THEN

            SELECT  INTO result_row.asources COUNT(DISTINCT b.id)
              FROM  biblio.record_entry b
                    JOIN asset.copy_vis_attr_cache acvac ON (acvac.record = b.id)
              WHERE b.id = ANY(all_arecords[1:browse_superpage_size])
                    AND (
                        acvac.vis_attr_vector @@ c_tests::query_int
                        OR b.vis_attr_vector @@ b_tests::query_int
                    );

            result_row.aaccurate := TRUE;

        END IF;

        IF result_row.sources > 0 OR result_row.asources > 0 THEN

            -- The function that calls this function needs row_number in order
            -- to correctly order results from two different runs of this
            -- functions.
            result_row.row_number := row_number;

            -- Now, if row_counter is still less than limit, return a row.  If
            -- not, but it is less than next_pivot_pos, continue on without
            -- returning actual result rows until we find
            -- that next pivot, and return it.

            IF row_counter < result_limit THEN
                result_row.browse_entry := rec.id;
                result_row.value := rec.value;

                RETURN NEXT result_row;
            ELSE
                result_row.browse_entry := NULL;
                result_row.authorities := NULL;
                result_row.fields := NULL;
                result_row.value := NULL;
                result_row.sources := NULL;
                result_row.sees := NULL;
                result_row.accurate := NULL;
                result_row.aaccurate := NULL;
                result_row.pivot_point := rec.id;

                IF row_counter >= next_pivot_pos THEN
                    RETURN NEXT result_row;
                    RETURN;
                END IF;
            END IF;

            IF count_up_from_zero THEN
                row_number := row_number + 1;
            ELSE
                row_number := row_number - 1;
            END IF;

            -- row_counter is different from row_number.
            -- It simply counts up from zero so that we know when
            -- we've reached our limit.
            row_counter := row_counter + 1;
        END IF;
    END LOOP;
END;
$f$ LANGUAGE plpgsql ROWS 10;

DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON biblio.peer_bib_copy_map;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON biblio.record_entry;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON asset.copy;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON asset.call_number;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON asset.copy_location;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON serial.unit;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON config.copy_status;
DROP TRIGGER IF EXISTS a_opac_vis_mat_view_tgr ON actor.org_unit;

-- Upgrade the data!
INSERT INTO asset.copy_vis_attr_cache (target_copy, record, vis_attr_vector)
    SELECT  cp.id,
            cn.record,
            asset.calculate_copy_visibility_attribute_set(cp.id)
      FROM  asset.copy cp
            JOIN asset.call_number cn ON (cp.call_number = cn.id);

UPDATE biblio.record_entry SET vis_attr_vector = biblio.calculate_bib_visibility_attribute_set(id);

CREATE TRIGGER z_opac_vis_mat_view_tgr BEFORE INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_tgr AFTER INSERT OR DELETE ON biblio.peer_bib_copy_map FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_tgr AFTER UPDATE ON asset.call_number FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_del_tgr BEFORE DELETE ON asset.copy FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_del_tgr BEFORE DELETE ON serial.unit FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_tgr AFTER INSERT OR UPDATE ON asset.copy FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();
CREATE TRIGGER z_opac_vis_mat_view_tgr AFTER INSERT OR UPDATE ON serial.unit FOR EACH ROW EXECUTE PROCEDURE asset.cache_copy_visibility();

COMMIT;

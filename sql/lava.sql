/*

Create all the tables and data bases for a run
 
fbi will populate all of these tables.
lavaTool will consult them to figure out which bug to inject next, 
preferring bugs with lower icount for dua / ap, and updating the icount for those selected.
something else will update the scount field when a real bug gets found

*/


DROP TABLE IF EXISTS run_stats;

DROP TABLE IF EXISTS run;
DROP TABLE IF EXISTS build;
DROP TABLE IF EXISTS bug;

DROP TABLE IF EXISTS dua;
DROP TABLE IF EXISTS atp;


DROP TABLE IF EXISTS sourcefile;
DROP TABLE IF EXISTS inputfile;
DROP TABLE IF EXISTS lval;
DROP TABLE IF EXISTS atptype;

-- DROP TABLE IF EXISTS lava_lock;

-- drop database if exists tshark;
drop role if exists lava;


CREATE USER lava WITH PASSWORD 'llaavvaa';
-- create DATABASE tshark;
	
-- Table of source file names
CREATE TABLE sourcefile (
       sourcefile_id  serial primary key,
       sourcefile_nm  text unique not null  -- file name, full path
);
-- ALTER TABLE sourcefile ADD UNIQUE (nm);


-- Table of input file names
CREATE TABLE inputfile (
       inputfile_id  serial primary key,
       inputfile_nm  text unique not null -- file name, full path
);
-- ALTER TABLE inputfile ADD UNIQUE (nm);


-- Table of lvals
CREATE TABLE lval (
       lval_id  serial primary key,
       lval_nm  text unique not null -- how the lval appears in src, e.g., foo->bar or meh[i].fez
);


-- Table of AttackPoint types
CREATE TABLE atptype (    
       atptype_id  serial primary key,
       atptype_nm  text unique not null -- memcpy, malloc, etc
);



drop table if exists unique_taint_set;

CREATE TABLE unique_taint_set (
  ptr          numeric,
  file_offset  integer,
  UNIQUE(ptr,file_offset)
); 

    
-- CREATE OR REPLACE FUNCTION take_lock ( h text, r text, w datetime ) 
--    if (select (*) from 

-- Table of dead uncomplicated and available data
-- A dua is one or more bytes of an lval at a particular source location
-- that is directly controllable by some input bytes, but not a complicated
-- function of those bytes, but is also dead in the sense that it does not
-- taint many branches
CREATE TABLE dua (
       dua_id          serial primary key, 
       filename_id	   integer references sourcefile, -- source file containing this dua (see SourceFile table)
       line	           integer,                       -- line in source file
       lval_id	       integer references lval,       -- name of the lval, at least some bytes of which are dua 
       insertionpoint  integer,                       -- tells us if dua came from a taint query before (1) or after (2) the fn call   
       file_offset     integer[],                     -- bytes in the input file that taint this dua                                   
       lval_taint	   numeric[],                     -- lval_taint[0] is ptr to taint set.  0 means untainted
       inputfile_id    integer references inputfile,  -- input file that gave us this dua                                              
       max_tcn         real,                          -- max taint compute number across bytes in this dua                             
       max_card	       integer,                       -- max cardinality of a taint label set for any byte in the dua                  
       max_liveness    float,                         -- max liveness of any label in any taint label set for any byte in the dua      
       dua_icount      integer,                       -- number of times used to inject a bug                                          
       dua_scount      integer,                        -- number of times used to inject a bug that was successful                      
       instr           numeric,                       -- instruction count for this dua (uint64) 
       UNIQUE(filename_id,line,lval_id,insertionpoint,file_offset,lval_taint,inputfile_id)
);



-- Table of attack points
-- An attack point is a 
CREATE TABLE atp (
       atp_id      	  serial primary key, 
       filename_id	  integer references sourcefile,   -- source file containing this ap (see SourceFile table)
       line	          integer,                         -- line in source file
       typ_id	      integer references atptype,      -- type of attack point (see AttackPoint table)
       inputfile_id   integer references inputfile,    -- input file that gave us this dua
       atp_icount     integer,                         -- number of times used to inject a bug                    
       atp_scount     integer,                         -- number of times used to inject a bug that was successful
       UNIQUE(filename_id,line,typ_id,inputfile_id)
);


-- Table of bug possible injections
-- A bug consists of a dua and an attack point
CREATE TABLE bug (
       bug_id      serial primary key,
       dua_id	   integer references dua,     -- id of dua
       atp_id      integer references atp,     -- id of attack point
       inj         boolean,                    -- true iff we have attempted to inj & build at least once
       UNIQUE(dua_id,atp_id)
);


-- Table of inject / build attempts
CREATE TABLE build (
       build_id     serial primary key,   -- this can be used to refer to a git branch or a patchfile name
       bugs         integer[],            -- list of bug ids that were injected into the source  (should an array of foreign keys but that's not possible?)
       binpath      text,                 -- path to executable built
       compile      boolean,              -- true if the build compiled
       UNIQUE(bugs,binpath)
);


-- Table of runs. 
CREATE TABLE run (
       run_id             serial primary key,
       build_id           integer references build,   -- the build used to generate this exe
       fuzz               boolean,                    -- true if program ran on fuzzed input, false if it ran on orig input
       exitcode           integer,                    -- exit code of program
       output_lines       text,                       -- captured output of program
       success            boolean                     -- true unless some kind of exception in python script fuzzing / testing
);


create table run_stats  (
       run_id         integer references run,
       exitcode       int,
       max_liveness   real,
       max_tcn        int,
       max_card       int
);  



GRANT SELECT, INSERT, UPDATE, DELETE ON sourcefile TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON inputfile TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON lval TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON atptype TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON dua TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON atp TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON bug TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON build TO lava;
GRANT SELECT, INSERT, UPDATE, DELETE ON run TO lava;

-- grant all privileges on all tables in schema public to lava;










drop function if exists  next_bug();
drop function if exists  num_rows(text);
drop function if exists  one();
drop function if exists  set_count(text);
drop function if exists  set_to_inj(real);
drop function if exists  take_lava_lock(text);



-- count rows in table
create or replace function num_rows(tablename text) returns integer 
as $$ 
  cmd = "select count (*) from " + tablename + ";"
  rv = plpy.execute(cmd, 1)
  return rv[0]["count"]
$$ LANGUAGE plpythonu;




-- update a random set of rows in bug table to be injected
-- NB: This is for testing purposes
create or replace function rand_set_to_inj(prob real) returns integer
as $$
  res = plpy.execute("select num_rows('bug')")
  n = res[0]['num_rows']
  ni = 0
  for i in range(n):
    import random
    if (random.random() < prob):
      cmd = "update bug set inj=true where bug_id=%d;" % i
      rv = plpy.execute(cmd, 1)
      ni += 1
  return ni
$$ LANGUAGE plpythonu;




-- sets count for table to random num
-- NB: This is for testing purposes
create or replace function rand_set_count(tablename text) returns void
as $$
  res = plpy.execute("select num_rows('%s')" % tablename)
  n = res[0]['num_rows']
  for i in range(n):
    import random
    cmd = "update %s set %s_icount=%d where %s_id=%d;" % (tablename, tablename, random.randint(0,1000), tablename, i)
    rv = plpy.execute(cmd, 1)
$$ LANGUAGE plpythonu;
  


drop type if exists bug_info;

create type bug_info as (
  score  int,
  bug    int,
  dua    int,
  atp    int
);                                                                                                                                                                   

  

/*
  next_bug()

 returns next bug to work on
 first, get set of bugs that have not been injected
 consider each, and for each compute a score that is the sum of the 
 counts for the dua and atp.  
 The bug that gets retured is the one for which that score is minimized.
 update count for dua and atp in bug that was chosen.
 and set the inj field to true for the chosen bug.

*/ 


/*
 tshark=# select * from next_bug();

  bug  | dua | atp 
-------+-----+-----
 13838 | 478 |  30
*/
create or replace function next_bug() returns bug_info
as $$
  # otherwise two injector processes might try to inject same bug
  plpy.execute("lock table bug;")
  plpy.execute("lock table dua;")
  plpy.execute("lock table atp;")
  reses = plpy.execute("select * from bug,dua,atp where bug.inj=false and dua.dua_id=bug.dua_id and atp.atp_id=bug.atp_id;")
  # consider each bug that hasnt yet been injected
  # keep track of bug that has lowest icount for *either* its dua or ap
  # that is the one we will inject
  min_score = 1000000
  b_argmin = ""
  d_argmin = ""
  a_argmin = ""
  for res in reses:
    # if the bigger of the two counts is smaller than min_score
    # then this bug is best seen so far
    bigger = res["dua_icount"] 
    if res["atp_icount"] > bigger:
      bigger = res["atp_icount"] 
    if bigger < min_score:
      min_score = bigger
      b_argmin = res["bug_id"]
      d_argmin = res["dua_id"]
      a_argmin = res["atp_id"]
  # grab it by setting the inj field
  res = plpy.execute("update bug set inj=true where bug_id=%d" % b_argmin)
  # update icounts for dua and atp
  res = plpy.execute("update dua set dua_icount=dua_icount+1 where dua_id=%d;" % d_argmin)
  res = plpy.execute("update atp set atp_icount=atp_icount+1 where atp_id=%d;" % a_argmin)
  #  return bug + score
  return { "score": min_score, "bug": b_argmin, "dua" : d_argmin, "atp": a_argmin }
$$ LANGUAGE plpythonu;



create or replace function remaining_uninjected_bugs() returns int
as $$
    reses = plpy.execute("select * from bug where bug.inj=false")
    return len(reses)
$$ LANGUAGE plpythonu;



create or replace function compute_run_stats() returns void
as $$
  # should give us the set of bugs (id) that have been successfully injected, compiled, and tested on a fuzzed input
  reses = plpy.execute("select exitcode,run_id,bugs[1] from run,build where run.build_id = build.build_id;")
  for res in reses:
    run_id = int(res["run_id"])
    bug_id = int(res["bugs"])
    exitcode = int(res["exitcode"])
    r2 = plpy.execute("select max_liveness, max_tcn, max_card from dua,bug where dua.dua_id = bug.dua_id and bug.bug_id = %d;" % bug_id)
    r = r2[0]
    (max_liveness, max_tcn, max_card) = (float(r["max_liveness"]), int(r["max_tcn"]), int(r["max_card"]))
    plpy.execute("insert into run_stats (run_id, exitcode, max_liveness, max_tcn, max_card) values (%d, %d, %.3f, %d, %d);" % (run_id,exitcode,max_liveness, max_tcn, max_card))
#  return { "bug_id": bug_id, "exitcode": exitcode, "max_liveness" : max_liveness, "max_tcn": max_tcn, "max_card": max_card }
$$ LANGUAGE plpythonu;    



/*
  clears all counts in dua / atp
  resets all bugs to inj = False
  drops build and run tables
*/
create or replace function reset_lava() returns void
as $$
  plpy.execute("DELETE FROM run_stats;")
  plpy.execute("DELETE FROM run;")
  plpy.execute("DELETE FROM build;")
  plpy.execute("UPDATE dua set dua_icount = 0, dua_scount = 0;")
  plpy.execute("UPDATE atp set atp_icount = 0, atp_scount = 0;")
  plpy.execute("UPDATE bug set inj=False;")
$$ LANGUAGE plpythonu;


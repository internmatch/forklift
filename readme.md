# Forklift
Moving heavy databases around.

![picture](https://raw.github.com/taskrabbit/forklift/master/forklift.jpg)

---
## What?
Forklift is a ruby gem that can help you collect, augment, and save copies of your mySQL databases.  This is often called an ["ETL" tool](http://en.wikipedia.org/wiki/Extract,_transform,_load) as the steps in this process mirror the actions of "Extracting the data", "Transforming the data", and finally "Loading the data" into its final place.

With Forklift, you create a plan about how to manipulate your data. The process for this involves (at least) 3 databases:

- Live set
- Working Database
- Final Database

The Live set is first loaded into the working set.  Then, any transformations/manipulations are run on the data in the working set.  This might include normalizing or cleaning up data which was great in production, but hard for analysts to use.  Finally, when all of your transformations are complete, that data is loaded into the final database.

Forklift is appropriate to use by itself or integrated within a larger project.  Forklift aims to be as fast as can be by using native mySQL copy commands and eschewing all ORMs and other RAM hogs.

## Features
- Can extract data from both local and remote database servers (coming soon)
- Can preform optional integrity checks on your source data to determine if this run of Forklift should be preformed
- Can run each extract step either each run or only every-so-often
- Can run each Transform step either each run or only every-so-often
- Data kept in the woking database after each run to be used on subsequent runs
- Only ETL'd tables will be copied into the final database, leaving other tables untouched
- Emails sent on errors

## Example Annotated Plan

In Forklift, you build a plan.  You can add any action to the plan in any order before you run it.  You can have 0 or many actions of each type.  

```ruby
require 'rubygems'
require 'bundler'
Bundler.require(:default)
require 'forklift/forklift'

#########
# SETUP #
#########

forklift = Forklift::Plan.new({
  
  :local_connection => {
    :host => "localhost",
    :username => "root",
    :password => nil,
  },
  
  :remote_connections => [
    {
      :name => "remote_connection_a",
      :host => "192.168.0.0",
      :username => "XXX",
      :password => "XXX",
    },
    {
      :name => "remote_connection_b",
      :host => "192.168.0.1",
      :username => "XXX",
      :password => "XXX",
    },
  ],

  :final_database => "FINAL",
  :working_database => "WORKING",

  :do_dump? => true,
  :dump_file => "/data/backups/dump-#{Time.new}.sql.gz",

  :do_email? => true,
  :email_to => ['XXX'],
  :email_options => { 
    :via => :smtp, 
    :via_options => {
      :address              => 'smtp.gmail.com',
      :port                 => '587',
      :enable_starttls_auto => true,
      :user_name            => "XXX",
      :password             => "XXX",
      :authentication       => :plain,
    } 
  }

})

##########
# CHECKS #
##########

forklift.check_local_source({
  :name => 'CHECK_FOR_NEW_DATA',
  :database => 'test',
  :query => 'select (select max(created_at) from new_table) > (select date_sub(NOW(), interval 1 day))',
  :expected => '1'
})

forklift.check_remote_source({
  :connection_name => "remote_connection_b",
  :name => 'ANOTHER_CHECK',
  :database => 'stuff',
  :query => 'select count(1) from people',
  :expected => '100'
})

###########
# EXTRACT #
###########

forklift.import_local_database({
  :database => "database_1",
  :prefix => false,
  :frequency => 24 * 60 * 60,
})

forklift.import_remote_database({
  :connection_name => 'remote_connection_a',
  :database => "database_2",
  :prefix => true,
  :skip => ['schema_migrations']
})

#############
# TRANSFORM #
#############

transformation_base = File.dirname(__FILE__) + "/transformations"

forklift.transform_sql({
  :file => "#{transformation_base}/calendars/create_calendars.sql",
  :frequency => 24 * 60 * 60,
})

forklift.transform_ruby({
  :file => "#{transformation_base}/test/test.rb",
})

#######
# RUN #
#######

forklift.run

```

## Workflow

```ruby
def run
  lock_pidfile                # Ensure that only one instance of Forklift is running
  rebuild_working_database    # Ensure that the working database exists
  ensure_forklift_data_table  # Ensure that the metadata table for forklift exists (used for frequency calculations)
  
  run_checks                  # Preform any data integrity checks
  run_extractions             # Extact data from the life databases into the working database
  run_transformations         # Preform any Transformations
  run_load                    # Load the manipulated data into the final database
  
  save_dump                   # mySQLdump the new final database for safe keeping
  send_email                  # Email folks the status of this forklift
  unlock_pidfile              # Cleanup the pidfile so I can run next time
end
```

## Transformations

Forklift allows you to create both Ruby transformations and SQL transformations

### Ruby Transformations
- SQL Transformations are kept in a file ending in `.rb`
- Ruby Transformations should define a class which matches the name of the file (IE: class `MyTransformation` would be in a file called `my_transformation.rb`
- `logger.log(message)` is the best way to log but `logger.debug` is also available
- `database` is a string containing the name of the `working` database
- `connection` is an instance of `Forklift::Connection` and `connection.connection` is a raw mysql2 connection
- Classes need to define a `transform(connection, database, logger)` IE:

```ruby
class Test

  def transform(connection, database, logger)
    logger.log "Running on DB: #{database}"
    logger.log "Counting users..."
    connection.q("USE `#{database}`")
    users_count = connection.q("count(1) as 'users_count' from `users`")
    logger.log("There were #{users_count} users")
  end

end
```

### SQL Transformations
- SQL Transformations are kept in a file ending in `.sql`
- You can have many SQL statements per file
- SQL will be executed linearly as it is written in the file

SQL Transformations can be used to [generate new tables like this](http://stackoverflow.com/questions/1201874/calendar-table-for-data-warehouse) as well


## Defaults

The defaults for a new `Forklift::Plan` are:

```ruby
{
   :project_root => Dir.pwd,
   :threads => 4,
   :lock_with_pid? => true,

   :final_database => {},
   :local_database => {},
   :forklift_data_table => '_forklift',
   
   :verbose? => true,

   :do_checks? => true,
   :do_extract? => true,
   :do_transform? => true,
   :do_load? => true,
   :do_email? => false,
   :do_dump? => false,
 }
```

## Methods

### Test

```ruby
forklift.check_local_source({
  :name => STRING,     # A name for the test
  :database => STRING, # The Database to test
  :query => STRING,    # The Query to Run.  Needs to return only 1 row with 1 value
  :expected => STRING  # The response to compare against
})

forklift.check_remote_source({
  :connection_name => STRING,  # The name of the remote_connection
  :name => STRING,             # A name for the test
  :database => STRING,         # The Database to test
  :query => STRING,            # The Query to Run.  Needs to return only 1 row with 1 value
  :expected => STRING          # The response to compare against
})
```

### Extract

```ruby
forklift.import_local_database({
  :database => STRING,              # The Database to Extract
  :prefix => BOOLEAN,               # Should we prefix the names of all tables in this database when imported wight the database?
  :frequency => INTEGER (seconds),  # How often should we import this database?
  :skip => ARRAY OR STRINGS	         # A list of tables to ignore and not import
})

forklift.import_remote_database({
  :connection_name => STRING,       # The name of the remote_connection
  :database => STRING,              # The Database to Extract
  :prefix => BOOLEAN,               # Should we prefix the names of all tables in this database when imported wight the database?
  :frequency => INTEGER (seconds),  # How often should we import this database?
  :skip => ARRAY OR STRINGS	         # A list of tables to ignore and not import
})
```

### Transform

```ruby
forklift.transform_sql({
  :file => STRING,                 # The transformation file to run
  :frequency => INTEGER (seconds), # How often should we run this transformation?
})

forklift.transform_ruby({
  :file => STRING,                 # The transformation file to run
  :frequency => INTEGER (seconds), # How often should we run this transformation?
})
```

## Options & Notes
- email_options is a hash consumed by the [Pony mail gem](https://github.com/benprew/pony)
- Forklift's logger is [Lumberjack](https://github.com/bdurand/lumberjack) with a wrapper to also echo the log lines to stdout and save them to an array to be accessed later by the email system.
- The connections hash will be passed directly to a [mysql2](https://github.com/brianmario/mysql2) connection.  Follow the link to see all the available options.


## Limitations
- forklift must be running on the same physical server as the `working` and final `databases`
- mySQL only (the [mysql2](https://github.com/brianmario/mysql2) gem specifically)

## Roadmap to V1
- remote import functions
- moving the `mysqldump` output off of the server
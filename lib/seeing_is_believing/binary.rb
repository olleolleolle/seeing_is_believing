require 'seeing_is_believing'
require 'seeing_is_believing/binary/parse_args'
require 'seeing_is_believing/binary/interpret_flags'
require 'seeing_is_believing/binary/remove_annotations'

class SeeingIsBelieving
  module Binary
    SUCCESS_STATUS              = 0
    DISPLAYABLE_ERROR_STATUS    = 1 # e.g. user code raises an exception (we can display this in the output)
    NONDISPLAYABLE_ERROR_STATUS = 2 # e.g. SiB was invoked incorrectly

    def self.call(argv, stdin, stdout, stderr)
      flags   = ParseArgs.call(argv)
      options = InterpretFlags.new(flags, stdin, stdout)

      if options.errors.any?
        stderr.puts options.errors.join("\n")
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if options.print_help?  # TODO: Should this be first?
        stdout.puts options.help_screen
        return SUCCESS_STATUS
      end

      if options.print_version?
        stdout.puts SeeingIsBelieving::VERSION
        return SUCCESS_STATUS
      end

      if options.provided_filename_dne?
        stderr.puts "#{options.filename} does not exist!"
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if options.print_cleaned?
        stdout.print RemoveAnnotations.call(options.prepared_body, true, options.marker_regexes)
        return SUCCESS_STATUS
      end

      require 'seeing_is_believing/code'
      syntax = Code.new(options.body, options.filename).syntax
      if syntax.invalid?
        stderr.puts "#{syntax.line_number}: #{syntax.error_message}"
        return NONDISPLAYABLE_ERROR_STATUS
      end

      results, program_timedout, unexpected_exception =
        evaluate_program(options.prepared_body, options.lib_options)

      if program_timedout
        stderr.puts "Timeout Error after #{options.timeout} seconds!"
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if unexpected_exception.kind_of? BugInSib
        stderr.puts unexpected_exception.message
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if unexpected_exception
        stderr.puts unexpected_exception.class,
                    unexpected_exception.message,
                    "",
                    unexpected_exception.backtrace
        return NONDISPLAYABLE_ERROR_STATUS
      end

      if options.result_as_json?
        require 'json'
        stdout.puts JSON.dump(result_as_data_structure(results))
        return SUCCESS_STATUS
      end

      # TODO: Annoying debugger stuff from annotators can move up to here
      # or maybe debugging goes to stderr, and we still print this anyway?
      annotated = options.annotator.call(options.prepared_body,
                                         results,
                                         options.annotator_options)
      annotated = annotated[0...-1] if options.body[-1] != "\n"
      stdout.print annotated

      if options.inherit_exit_status?
        results.exitstatus
      elsif results.exitstatus != 0 # e.g. `exit 0` raises SystemExit but isn't an error
        DISPLAYABLE_ERROR_STATUS
      else
        SUCCESS_STATUS
      end
    end

    private

    def self.evaluate_program(body, options)
      return SeeingIsBelieving.call(body, options), false, nil
    rescue Timeout::Error
      return nil, true, nil
    rescue Exception
      return nil, false, $!
    end

    def self.result_as_data_structure(results)
      exception = results.has_exception? && { line_number_in_this_file: results.exception.line_number,
                                              class_name:               results.exception.class_name,
                                              message:                  results.exception.message,
                                              backtrace:                results.exception.backtrace,
                                            }
      { stdout:      results.stdout,
        stderr:      results.stderr,
        exit_status: results.exitstatus,
        exception:   exception,
        lines:       results.each.with_object(Hash.new).with_index(1) { |(result, hash), line_number| hash[line_number] = result },
      }
    end
  end
end

require 'fastercsv'

class SubmissionsController < ApplicationController
  include SubmissionsHelper
  
  before_filter    :authorize_only_for_admin, :except => [:populate_file_manager, :browse,
  :index, :file_manager, :update_files, :hand_in, :download, :populate_submissions_table, :collect_and_begin_grading]
  before_filter    :authorize_for_ta_and_admin, :only => [:browse, :index, :populate_submissions_table, :collect_and_begin_grading]
 
  def repo_browser
    @grouping = Grouping.find(params[:id])
    @assignment = @grouping.assignment
    @repository_name = @grouping.group.repository_name
  end
  
  def find_revision
    @grouping = Grouping.find(params[:id])
    @assignment = @grouping.assignment
    repo = @grouping.group.repo
    begin
      case params[:find_revision_by]
      when "revision_timestamp"
        @revision = repo.get_revision_by_timestamp(Time.parse(params[:revision_timestamp]))
      when "revision_number"
        @revision = repo.get_revision(params[:revision_number].to_i)
      else
        @revision = repo.get_latest_revision
      end
      @revision_number = @revision.revision_number
      @directories = @revision.directories_at_path(File.join(@assignment.repository_folder, '/'))
      @files = @revision.files_at_path(File.join(@assignment.repository_folder, '/'))
    rescue Exception => @find_revision_error
      render :action => 'repo_browser/find_revision_error'
      return
    end
    @table_rows = {} 
    @files.sort.each do |file_name, file|
      @table_rows[file.id] = construct_repo_browser_table_row(file_name, file)
    end
    render :action => 'repo_browser/populate_repo_browser'
  end
 
  def file_manager
    @assignment = Assignment.find(params[:id])
    @grouping = current_user.accepted_grouping_for(@assignment.id)
    user_group = @grouping.group
    path = params[:path] || '/'
    repo = user_group.repo
    @revision = repo.get_latest_revision
    @directories = @revision.directories_at_path(File.join(@assignment.repository_folder, path))
    @files = @revision.files_at_path(File.join(@assignment.repository_folder, path))
  
    @missing_assignment_files = []
    @assignment.assignment_files.each do |assignment_file|
      if !@revision.path_exists?(File.join(@assignment.repository_folder,
      assignment_file.filename))
        @missing_assignment_files.push(assignment_file)
      end
    end
  end
  
  def populate_file_manager
    @assignment = Assignment.find(params[:id])
    @grouping = current_user.accepted_grouping_for(@assignment.id)   
    user_group = @grouping.group
    revision_number= params[:revision_number]
    path = params[:path] || '/'
    repo = user_group.repo
    if revision_number.nil?
      @revision = repo.get_latest_revision
    else
     @revision = repo.get_revision(revision_number.to_i)
    end
    @directories = @revision.directories_at_path(File.join(@assignment.repository_folder, path))
    @files = @revision.files_at_path(File.join(@assignment.repository_folder, path))
    @table_rows = {} 
    @files.sort.each do |file_name, file|
      @table_rows[file.id] = construct_file_manager_table_row(file_name, file)
    end
    render :action => 'populate'
  end
  
  def manually_collect_and_begin_grading
    grouping = Grouping.find(params[:id])
    assignment = grouping.assignment
    revision_number = params[:current_revision_number].to_i
    new_submission = Submission.create_by_revision_number(grouping, revision_number)
    new_submission = assignment.submission_rule.apply_submission_rule(new_submission)
    result = new_submission.result
    redirect_to :controller => 'results', :action => 'edit', :id => result.id
  end

  def collect_and_begin_grading
    assignment = Assignment.find(params[:id])
    if assignment.submission_rule.can_collect_now?
      grouping = Grouping.find(params[:grouping_id])
      time = assignment.submission_rule.calculate_collection_time.localtime
      # Create a new Submission by timestamp.
      # A Result is automatically attached to this Submission, thanks to some callback
      # logic inside the Submission model
      new_submission = Submission.create_by_timestamp(grouping, time)
      # Apply the SubmissionRule
      new_submission = assignment.submission_rule.apply_submission_rule(new_submission)
      result = new_submission.result
      redirect_to :controller => 'results', :action => 'edit', :id => result.id
      return
    end
    redirect_to :action => 'browse', :id => assignment.id
  end
  
  
  def populate_submissions_table
    assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :accepted_students, :group, {:submissions => :result}]}, {:submission_rule => :periods}]) 
    
    @details = params[:details]
    
    # If the current user is a TA, then we need to get the Groupings
    # that are assigned for them to mark.  If they're an Admin, then
    # we need to give them a list of all Groupings for this Assignment.
    if current_user.ta?
      groupings = []
      assignment.ta_memberships.find_all_by_user_id(current_user.id).each do |membership|
        groupings.push(membership.grouping)
      end
    elsif current_user.admin?
      groupings = assignment.groupings
    end
    
    @table_rows = {} 
    groupings.each do |grouping|
      @table_rows[grouping.id] = construct_submissions_table_row(grouping, assignment)
    end

    render :action => 'populate'
  end

  def browse
    @assignment = Assignment.find(params[:id])
    @details = params[:details]
  end
  
  def index
    @assignments = Assignment.all(:order => :id)
    render :action => 'index', :layout => 'sidebar'
  end

  # controller handles transactional submission of files
  def update_files
    assignment_id = params[:id]
    assignment = Assignment.find(assignment_id)
    path = params[:path] || '/'
    grouping = current_user.accepted_grouping_for(assignment_id)
    if !grouping.is_valid?
      redirect_to :action => :file_manager, :id => assignment_id
      return
    end
    repo = grouping.group.repo
       
    assignment_folder = File.join(assignment.repository_folder, path)
    
    # Get the revision numbers for the files that we've seen - these
    # values will be the "expected revision numbers" that we'll provide
    # to the transaction to ensure that we don't overwrite a file that's
    # been revised since the user last saw it.
    file_revisions = params[:file_revisions].nil? ? [] : params[:file_revisions]
    
    # The files that will be replaced - just give an empty array
    # if params[:replace_files] is nil
    replace_files = params[:replace_files].nil? ? {} : params[:replace_files]

    # The files that will be deleted
    delete_files = params[:delete_files].nil? ? {} : params[:delete_files]

    # The files that will be added
    new_files = params[:new_files].nil? ? {} : params[:new_files]
    
    # Create transaction, setting the author.  Timestamp is implicit.
    txn = repo.get_transaction(current_user.user_name)

    begin
      # delete files marked for deletion
      delete_files.keys.each do |filename|
        txn.remove(File.join(assignment_folder, filename), file_revisions[filename])
      end
    
      # Replace files
      replace_files.each do |filename, file_object|
        txn.replace(File.join(assignment_folder, filename), file_object.read, file_object.content_type, file_revisions[filename])
      end

      # Add new files
      new_files.each do |file_object|
        # sanitize_file_name in SubmissionsHelper
        if file_object.original_filename.nil?
          raise "Invalid file name on submitted file"
        end
        txn.add(File.join(assignment_folder, sanitize_file_name(file_object.original_filename)), file_object.read, file_object.content_type)
      end

      # finish transaction
      if !txn.has_jobs?
        flash[:transaction_warning] = "No actions were detected in the last submit.  Nothing was changed."
        redirect_to :action => "file_manager", :id => assignment_id
        return
      end
      if !repo.commit(txn)
        flash[:update_conflicts] = txn.conflicts
      end
      
      # Are we past collection time?    
      if assignment.submission_rule.can_collect_now?
        flash[:commit_notice] = assignment.submission_rule.commit_after_collection_message(grouping)
      end
      
      redirect_to :action => "file_manager", :id => assignment_id
      
    rescue Exception => e
      flash[:commit_error] = e.message
      redirect_to :action => "file_manager", :id => assignment_id
    end
  end
  
  def download
    @assignment = Assignment.find(params[:id])
    # find_appropriate_grouping can be found in SubmissionsHelper
    @grouping = find_appropriate_grouping(@assignment.id, params)
    revision_number = params[:revision_number]
    path = params[:path] || '/'
    repo = @grouping.group.repo
    if revision_number.nil?
      @revision = repo.get_latest_revision
    else
      @revision = repo.get_revision(revision_number.to_i)
    end
    
    begin 
     file = @revision.files_at_path(File.join(@assignment.repository_folder, path))[params[:file_name]]
     file_contents = repo.download_as_string(file)
    rescue Exception => e
      render :text => "Could not download #{params[:file_name]}: #{e.message}.  File may be missing."
      return
    end
    if SubmissionFile.is_binary?(file_contents)
      # If the file appears to be binary, send it as a download
      send_data file_contents, :disposition => 'attachment', :filename => params[:file_name]  
    else
      # Otherwise, blast it out to the screen
      render :text => file_contents, :layout => 'sanitized_html'
    end
  end 

  def update_submissions
    return unless request.post?
    if params[:groupings].nil?
      flash[:release_results] = "Select a group"
    else
      if params[:release_results]
        flash[:release_errors] = []
        params[:groupings].each do |grouping_id|
          grouping = Grouping.find(grouping_id)
          if !grouping.has_submission?
            # TODO:  Neaten this up...
            flash[:release_errors].push("Grouping ID:#{grouping_id} had no submission")
            next
          end
          submission = grouping.get_submission_used
          if !submission.has_result?
            # TODO:  Neaten this up...
            flash[:release_errors].push("Grouping ID:#{grouping_id} had no result")
            next     
          end
          if submission.result.marking_state != Result::MARKING_STATES[:complete]
            flash[:release_errors].push("Can not release result for grouping #{grouping.id}: the marking state is not complete")
            next
          end
          if flash[:release_errors].nil? or flash[:release_errors].size == 0
            flash[:release_errors] = nil
          end
          submission.result.released_to_students = true
          submission.result.save        
        end
      elsif params[:unrelease_results]
        params[:groupings].each do |g|
          grouping = Grouping.find(g)
          grouping.get_submission_used.result.unrelease_results
        end
      end
    end
    redirect_to :action => 'browse', :id => params[:id]
    if !params[:groupings].nil?
      grouping = Grouping.find(params[:groupings].first)
      grouping.assignment.set_results_average
    end
  end


  def unrelease
    return unless request.post?
    if params[:groupings].nil?
      flash[:release_results] = "Select a group"
    else
      params[:groupings].each do |g|
        g.unrelease_results
      end
    end
    redirect_to :action => 'browse', :id => params[:id]
  end
  
  def download_csv_report
    assignment = Assignment.find(params[:id])
    students = Student.all
    rubric_criteria = assignment.rubric_criteria
    csv_string = FasterCSV.generate do |csv|
       students.each do |student|
         grouping = student.accepted_grouping_for(assignment.id)
         if !grouping.nil?
           if grouping.has_submission? 
             final_result = []
             submission = grouping.get_submission_used
             final_result.push(student.user_name)
             final_result.push(submission.result.total_mark)
             rubric_criteria.each do |rubric_criterion|
               mark = submission.result.marks.find_by_rubric_criterion_id(rubric_criterion.id)
               # TODO:  Should this really be 0, if no mark has been set?
               if mark.nil?
                 final_result.push(0)
               else
                 final_result.push(mark.mark || 0)
               end 
               final_result.push(rubric_criterion.weight)
             end
             final_result.push(submission.result.get_total_extra_points)
             final_result.push(submission.result.get_total_extra_percentage)
             membership = grouping.student_memberships.find_by_user_id(student.id)
             grace_period_deductions = student.grace_period_deductions.find_by_membership_id(membership.id)
             final_result.push(grace_period_deductions || 0)
             
             csv << final_result
           end
         end
       end

    end
     
    send_data csv_string, :disposition => 'attachment', :file_type => 'csv', :filename => "#{assignment.name} report.csv"
  end

end

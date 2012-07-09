###
#
# Copyright (c) 2011 Advanced Control and Acoustics
#
# @author   Stephen von Takach <steve@advancedcontrol.com.au>
# @copyright  2011 advancedcontrol.com.au
# @license  GNU LESSER GENERAL PUBLIC LICENSE Version 3
#
###

module Resolute
  class ResumablesController < ApplicationController
    respond_to :json
    ##
    # These are for testing 
    #
    def load_session
      session[:user] = 12
      render :text => "session loaded, folder path: #{Resolute.upload_folder}", :layout => false
    end
    
    def index
      user = get_current_user
      render :text => "user test: #{user}<br />App Class returned: #{inform_upload_completed(user, nil, nil, nil)}", :layout => false
    end
    #
    # Disabled in routes by default
    ##
    
    def resumable_upload
      user = get_current_user
      if user.nil?
        render :text => '{}', :layout => false, :status => :forbidden # 403
        return
      end
      
      if request.get?
        #
        # Request an upload id for the file described
        #
        resume = Resumable.new(params[:resume].merge({:user_id => user.to_s}))
        
        found = Resumable.all_of('$and' => [{:user_id => resume.user_id}, {:file_name => resume.file_name}, {:file_size => resume.file_size}])
        
        if(resume.file_modified.nil?) # Browsers may not send this. We'll use it if we can
          found = found.where(:file_modified => 'NULL').first
        else
          found = found.where(:file_modified => resume.file_modified).first
        end
        
        #
        # Is there an existing file? If not create an entry for this one
        #
        if found.nil?
          #
          # Check if file is a valid format before upload
          #
          resp = check_format_supported(user, resume.file_name, resume.custom_params)
          if resp != true
            process_bad_request(resp)
            return  # Ensure only a single call to render
          end
          resume.save
        else
          resume = found
          resume.touch    # Resumable file last accessed
        end
        
        render :json => {:file_id => resume.id, :next_part => resume.next_part}, :layout => false
      else
        #
        # Recieve a chunk of data and save it
        #
        resume = Resumable.find(params[:id])
        if resume.user_id != user.to_s
          render :text => '{}', :layout => false, :status => :forbidden # 403
          return
        end
        
        next_part = resume.apply_part(params[:part].to_i, params[:chunk])
        id = nil
        if next_part == false
          id = get_upload_id.to_s
          resp = inform_upload_completed(user, resume.file_name, resume.file_location, resume.custom_params, resume)
          
          #
          # Check response
          #
          if resp != true
            process_bad_request(resp)
            return  # Ensure only a single call to render
          else
            render json: {next_part: next_part, _id: id, name: resume.file_name  }, layout: false
            
            if !resume.destroyed?
              resume.destroy  # Destroy the DB entry for this resumable upload. Application logic is now managing the file
            end
            return
            
          end
        end
        
        render :json => {:next_part => next_part }, :layout => false
      end
    end
    
    def regular_upload  # Well still HTML5 (just not multi-part)
      logger.debug "Using non-multipart"
      user = get_current_user
      if user.nil?
        render :nothing => true, :layout => false, :status => :forbidden  # 403
        return
      end
      
      filepath = Resumable.sanitize_filename(params[:uploaded_file].original_filename, user)
      
      if !params[:custom_params].nil? # Normalise params
        params[:custom_params] = JSON.parse(params[:custom_params], {:symbolize_names => true})
      end
      
      #
      # Check if file is the correct format before copying out of temp folder
      #
      resp = check_format_supported(user, params[:uploaded_file].original_filename, params[:custom_params])
      if resp != true
        process_bad_request(resp)
        return  # Ensure only a single call to render
      end
      
      # file copy here
      FileUtils.cp params[:uploaded_file].tempfile.path, filepath
      
      # Grab document id to pass to client.
      id = get_upload_id.to_s
      
      #
      # Inform that upload is complete (file in uploads directory)
      #
      resp = false
      
      resp = inform_upload_completed(user, params[:uploaded_file].original_filename, filepath, params[:custom_params])
      if resp != true
        process_bad_request(resp)
        return  # Ensure only a single call to render
      end
      render :json => {_id: id, name: params[:uploaded_file].original_filename}, :layout => false
    end
    
    #protected
    
    def process_bad_request(resp)
      if resp.class == Array  # Assume error array
        render :json => {:error => resp}, :layout => false, :status => :not_acceptable  # 406
      else
        render :text => '{}', :layout => false, :status => :unprocessable_entity    # 422
      end
    end
    
    #
    # Get current user needs to be called in the context of the controller
    #
    def get_current_user
      #Resolute.current_user
      instance_eval &Resolute.current_user
    end
    
    def get_upload_id
      #Resolute.upload_id
      instance_eval &Resolute.upload_id
    end
    
    def inform_upload_completed(user, oringinal_name, current_path, custom_parameters = {}, db_entry = nil)
      result = {
        :user => user,
        :filename => oringinal_name,
        :filepath => current_path,
        :params => custom_parameters
      }
      return Resolute.upload_completed.bind(self).call(result)
    end
    
    def check_format_supported(user, filename, custom_parameters)
      file_info = {
        :user => user,
        :filename => filename,
        :params => custom_parameters
      }
      Resolute.check_supported.bind(self).call(file_info)
    end
  end
end

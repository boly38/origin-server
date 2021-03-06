class EmbCartController < BaseController
  include RestModelHelper
  before_filter :get_application
  action_log_tag_resource :app_cartridge

  def index
    cartridges = get_application_rest_cartridges(@application)
    render_success(:ok, "cartridges", cartridges, "Listing cartridges for application #{@application.name} under domain #{@application.domain_namespace}")
  end

  def show
    id = params[:id].presence
    status_messages = !params[:include].nil? and params[:include].split(",").include?("status_messages")

    cartname = CartridgeCache.find_cartridge(id, @application).name rescue id
    component_instance = @application.component_instances.find_by(cartridge_name: ComponentInstance.check_name!(cartname))
    cartridge = get_embedded_rest_cartridge(@application, component_instance, @application.group_instances_with_scale, @application.group_overrides, status_messages)
    render_success(:ok, "cartridge", cartridge, "Showing cartridge #{id} for application #{@application.name} under domain #{@application.domain_namespace}")
  end

  def create
    if @application.quarantined
      return render_upgrade_in_progress
    end

    authorize! :create_cartridge, @application

    user_env_vars = params[:environment_variables].presence
    Application.validate_user_env_variables(user_env_vars, true)

    specs = []
    if params[:cartridges].is_a?(Array)
      specs += params[:cartridges].map{ |p| p.is_a?(Hash) ? p : {name: String(p).presence}}
    elsif params[:cartridge].is_a? Hash
      specs << params[:cartridge]
    elsif params[:cartridge].is_a? String
      specs << params.merge(name: params[:cartridge]) # DEPRECATED
    else
      specs << params
    end
    CartridgeInstance.check_cartridge_specifications!(specs)
    return render_error(:unprocessable_entity, "Error in parameters. Cannot determine cartridge. Use 'cartridge'/'name'/'url'", 109) unless specs.all?{ |f| f[:name] or f[:url] }
    #return render_error(:unprocessable_entity, "Only one cartridge may be added at a time.", 109) unless specs.length == 1

    @application.domain.check_gear_sizes!(specs.map{ |f| f[:gear_size] }.compact.uniq, "gear_size")

    begin
      cartridges = CartridgeCache.find_and_download_cartridges(specs)
      group_overrides = CartridgeInstance.overrides_for(cartridges, @application)
      @application.validate_cartridge_instances!(cartridges)
      result = @application.add_features(cartridges.map(&:cartridge), group_overrides, nil, user_env_vars)
    rescue
      # If this was a request to add a url based cart, 
      # remove the entry from downloaded_cart_map if there is no corresponding component_instance created. 
      # This handles the cases where the exception is raised after populating the downloaded_cart_map,
      # but before the pending op for the new component/gear are created and executed
      unsets = {}
      @application.downloaded_cart_map.each do |k, v|
        cartridges.map(&:cartridge).each do |cartridge|
          if v["versioned_name"] == cartridge.name
            found = false
            @application.component_instances.each do |ci|
              if ci.cartridge_name ==  ci.cartridge_name
                found = true
                break
              end
            end
            unsets["downloaded_cart_map.#{k}"] = "" if !found
          end
        end
      end if cartridges.present?
      # Since this is outside the application lock, we are using unset instead of saving the modified cart map
      Application.where(:_id => @application._id).find_and_modify({"$unset"=> unsets}) if unsets.present?
      
      # this rescue block is only responsible for cleaning up the downloaded_cart_map
      # the exception should be re-raised to handle full error processing
      raise
    end

    rest = cartridges.map do |cart|
      component_instance = @application.component_instances.where(cartridge_name: cart.name).first
      get_embedded_rest_cartridge(@application, component_instance, @application.group_instances_with_scale, @application.group_overrides)
    end

    if rest.length > 1
      render_success(:created, "cartridges", rest, "Added #{cartridges.map(&:name).to_sentence} to application #{@application.name}", result)
    else
      render_success(:created, "cartridge",rest.first, "Added #{cartridges.first.name} to application #{@application.name}", result)
    end

  rescue OpenShift::GearLimitReachedException => ex
    render_error(:unprocessable_entity, "Unable to add cartridge: #{ex.message}", 104)

  rescue OpenShift::UserException => ex
    ex.field = nil if ex.field == "cartridge"
    raise
  end

  def destroy
    if @application.quarantined
      return render_upgrade_in_progress
    end

    authorize! :destroy_cartridge, @application

    id = params[:id].presence

    comp = @application.component_instances.find_by(cartridge_name: ComponentInstance.check_name!(id))
    feature = comp.cartridge_name #@application.get_feature(comp.cartridge_name, comp.component_name)
    raise Mongoid::Errors::DocumentNotFound.new(ComponentInstance, nil, [id]) if feature.nil?
    result = @application.remove_features([feature])
    status = requested_api_version <= 1.4 ? :no_content : :ok

    render_success(status, nil, nil, "Removed #{id} from application #{@application.name}", result)
  end

  def update
    id = ComponentInstance.check_name!(params[:id].presence)

    scales_from = Integer(params[:scales_from].presence) rescue nil
    scales_to = Integer(params[:scales_to].presence) rescue nil
    additional_storage = params[:additional_gear_storage].presence

    if scales_from.nil? and scales_to.nil? and additional_storage.nil?
      return render_error(:unprocessable_entity, "No update parameters specified.  Valid update parameters are: scales_from, scales_to, additional_gear_storage", 168)
    end

    authorize!(:scale_cartridge, @application) unless scales_from.nil? and scales_to.nil?
    authorize!(:change_gear_quota, @application) unless additional_storage.nil?

    begin
      additional_storage = Integer(additional_storage) if additional_storage
    rescue
      return render_error(:unprocessable_entity, "Invalid storage value provided.", 165, "additional_storage")
    end

    if !@application.scalable and ((scales_from and scales_from != 1) or (scales_to and scales_to != 1 and scales_to != -1))
      return render_error(:unprocessable_entity, "Application '#{@application.name}' is not scalable", 100, "name")
    end

    if scales_from and scales_from < 1
      return render_error(:unprocessable_entity, "Invalid scales_from factor #{scales_from} provided", 168, "scales_from")
    end

    if scales_to and (scales_to == 0 or scales_to < -1)
      return render_error(:unprocessable_entity, "Invalid scales_to factor #{scales_to} provided", 168, "scales_to")
    end

    if scales_to and scales_from and scales_to >= 1 and scales_to < scales_from
      return render_error(:unprocessable_entity, "Invalid scales_(from|to) factor provided", 168, "scales_to")
    end

    if @application.quarantined && (scales_from || scales_to)
      return render_upgrade_in_progress
    end

    component_instance = @application.component_instances.find_by(cartridge_name: id)

    if component_instance.nil?
      return render_error(:unprocessable_entity, "Invalid cartridge #{id} for application #{@application.name}", 168, "PATCH_APP_CARTRIDGE", "cartridge")
    end

    if component_instance.is_sparse?
      if scales_to and scales_to != 1
        return render_error(:unprocessable_entity, "The cartridge #{id} cannot be scaled.", 168, "PATCH_APP_CARTRIDGE", "scales_to")
      elsif scales_from and scales_from != 1
        return render_error(:unprocessable_entity, "The cartridge #{id} cannot be scaled.", 168, "PATCH_APP_CARTRIDGE", "scales_from")
      end
    end

    group_instance = @application.group_instances_with_scale.select{ |go| go.all_component_instances.include? component_instance }[0]

    if scales_to and scales_from.nil? and scales_to >= 1 and scales_to < group_instance.min
      return render_error(:unprocessable_entity, "The scales_to factor currently provided cannot be lower than the scales_from factor previously provided. Please specify both scales_(from|to) factors together to override.", 168, "scales_to")
    end

    if scales_from and scales_to.nil? and group_instance.max >= 1 and group_instance.max < scales_from
      return render_error(:unprocessable_entity, "The scales_from factor currently provided cannot be higher than the scales_to factor previously provided. Please specify both scales_(from|to) factors together to override.", 168, "scales_from")
    end

    result = @application.update_component_limits(component_instance, scales_from, scales_to, additional_storage)

    component_instance = @application.component_instances.find_by(cartridge_name: id)
    cartridge = get_embedded_rest_cartridge(@application, component_instance, @application.group_instances_with_scale, @application.group_overrides)

    render_success(:ok, "cartridge", cartridge, "Showing cartridge #{id} for application #{@application.name} under domain #{@application.domain_namespace}", result)
  end
end

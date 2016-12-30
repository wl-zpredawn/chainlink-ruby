describe AssignmentSnapshot, type: :model do

  describe "validations" do
    it { is_expected.to have_valid(:assignment).when(factory_create(:assignment)) }
    it { is_expected.not_to have_valid(:assignment).when(nil) }

    it { is_expected.to have_valid(:details).when(nil, '', {a: 1}) }

    it { is_expected.to have_valid(:progress).when(nil, 'started', 'completed', 'failed') }
    it { is_expected.not_to have_valid(:progress).when('', 'foo') }

    it { is_expected.to have_valid(:status).when(nil, 'in progress', 'completed', 'failed') }
    it { is_expected.not_to have_valid(:status).when('', 'foo') }

    it { is_expected.to have_valid(:xid).when(nil, SecureRandom.uuid) }
    it { is_expected.not_to have_valid(:xid).when('') }

    it { is_expected.to have_valid(:summary).when('anything', 'foo', nil, '') }
    context "when the snapshot is fulfilled" do
      subject { AssignmentSnapshot.new fulfilled: true }
      it { is_expected.to have_valid(:summary).when('anything', 'foo') }
      it { is_expected.not_to have_valid(:summary).when(nil, '') }
    end

    it { is_expected.to have_valid(:value).when(nil, '', SecureRandom.base64) }
  end

  describe "on create" do
    let(:snapshot) { factory_build :assignment_snapshot, assignment: assignment }
    let(:assignment) { factory_create :assignment }
    let(:adapter) { assignment.adapter }
    let(:adapter_response) do
      {
        fulfilled: false,
        xid: snapshot.xid,
      }
    end

    before do
      allow_any_instance_of(ExternalAdapter).to receive(:get_status)
        .with(snapshot)
        .and_return(hashie adapter_response)
    end

    it "generates an external ID" do
      expect {
        snapshot.save
      }.to change {
        snapshot.xid
      }.from(nil)
    end

    it "sets the progress to started" do
      expect {
        snapshot.save
      }.to change {
        snapshot.progress
      }.from(nil).to(AssignmentSnapshot::STARTED)
    end

    context "with adapters" do
      before do
        factory_create :adapter_assignment, assignment: assignment
        factory_create :adapter_assignment, assignment: assignment
        factory_create :adapter_assignment, assignment: assignment
        assignment.reload

        allow_any_instance_of(AdapterSnapshot).to receive(:start)
      end

      it "creates an adapter snapshot for each adapter of the assignment" do
        expect {
          snapshot.save
        }.to change {
          snapshot.adapter_snapshots.count
        }.by(+3)
      end

      it "sets the adapter index to the first possible" do
        expect {
          snapshot.save
        }.to change {
          snapshot.adapter_index
        }.from(nil).to(assignment.adapter_assignments.first.index)
      end

      it "starts the adapter snapshot pipeline process" do
        expect_any_instance_of(AdapterSnapshot).to receive(:start) do |adapter_snapshot|
          expect(adapter_snapshot).to eq(snapshot.current_adapter_snapshot)
        end

        snapshot.save
      end
    end

    context "when the adapter responds with more information" do
      let(:status) { Term::IN_PROGRESS }
      let(:value) { SecureRandom.hex }
      let(:details) { {key: SecureRandom.hex} }
      let(:adapter_response) do
        {
          status: status,
          fulfilled: true,
          details: details,
          value: value,
          xid: snapshot.xid,
        }
      end

      it "marks itself as fulfilled" do
        expect {
          snapshot.save
        }.to change {
          snapshot.fulfilled
        }.from(false).to(true)
      end

      it "records the information" do
        expect {
          snapshot.save
        }.to change {
          snapshot.status
        }.from(nil).to(status).and change {
          snapshot.value
        }.from(nil).to(value).and change {
          snapshot.details_json
        }.from(nil).to(details.to_json)
      end

      it "notifies the coordinator" do
        expect_any_instance_of(Coordinator).to receive(:snapshot) do |coordinator, id|
          expect(coordinator).to eq(assignment.coordinator)
          expect(id).to eq(snapshot.id)
        end

        snapshot.save
      end
    end

    context "when the adapter responds without information" do
      it "marks itself as unfulfilled" do
        expect {
          snapshot.save
        }.not_to change {
          snapshot.fulfilled
        }.from(false)
      end

      it "records the information" do
        expect {
          snapshot.save
        }.not_to change {
          snapshot.value
        }
      end

      it "does NOT notify the coordinator" do
        expect_any_instance_of(CoordinatorClient).not_to receive(:snapshot)

        snapshot.save
      end
    end

    context "when nothing is returned by the adapter" do
      let(:adapter_response) { nil }

      it "does NOT create a snapshot" do
        expect {
          snapshot.save
        }.not_to change {
          snapshot.persisted?
        }.from(false)
      end

      it "sends out a notifaction" do
        expect(Notification).to receive_message_chain(:delay, :snapshot_failure)
          .with(assignment, nil)

        snapshot.save
      end
    end

    context "when nothing is returned by the adapter" do
      let(:errors) { ["foo", "bar"] }
      let(:adapter_response) { { errors: errors } }

      it "does NOT create a snapshot" do
        expect {
          snapshot.save
        }.not_to change {
          snapshot.persisted?
        }.from(false)
      end

      it "sends out a notifaction" do
        expect(Notification).to receive_message_chain(:delay, :snapshot_failure)
          .with(assignment, errors)

        snapshot.save
      end
    end

    context "when the snapshot already has an external ID" do
      let(:xid) { SecureRandom.uuid }

      before { snapshot.xid = xid }

      it "generates an external ID" do
        expect {
          snapshot.save
        }.not_to change {
          snapshot.xid
        }.from(xid)
      end
    end
  end

  describe "on save" do
    let!(:snapshot) { factory_create :assignment_snapshot, fulfilled: pre_fulfilled }

    context "when the snapshot is already fulfilled" do
      let(:pre_fulfilled) { true }

      context "and it is marked as fulfilled" do
        it "does NOT notify the coordinator" do
          expect_any_instance_of(CoordinatorClient).not_to receive(:snapshot)

          snapshot.update_attributes details: {foo: SecureRandom.base64}, fulfilled: true
        end
      end

      context "and it is marked as unfulfilled" do
        it "does NOT notify the coordinator" do
          expect_any_instance_of(CoordinatorClient).not_to receive(:snapshot)

          response = snapshot.update_attributes({
            details: {foo: SecureRandom.base64},
            fulfilled: false
          })

          expect(response).to be_falsey
        end
      end
    end

    context "when the snapshot is not already fulfilled" do
      let(:pre_fulfilled) { false }

      context "and it is marked as fulfilled" do
        it "does notify the coordinator" do
          expect(snapshot.assignment.coordinator).to receive(:snapshot)
            .with(snapshot.id)

          snapshot.update_attributes details: {foo: SecureRandom.base64}, fulfilled: true
        end
      end

      context "and it is marked as unfulfilled" do
        it "does NOT notify the coordinator" do
          expect_any_instance_of(CoordinatorClient).not_to receive(:snapshot)

          snapshot.update_attributes details: {foo: SecureRandom.base64}, fulfilled: false
        end
      end
    end

    context "when the adapter is an Ethereum oracle" do
      let(:oracle) { factory_create :ethereum_oracle }
      let(:assignment) { factory_create :assignment, adapter: oracle }
      let(:snapshot) { assignment.snapshots.build }

      it "creates a fulfilled snapshot" do
        expect {
          snapshot.save
        }.to change {
          oracle.reload.writes.count
        }.by(+1)
      end

      it "sets all the values off of the oracle write record" do
        snapshot.save
        write = EthereumOracleWrite.last

        expect(snapshot).to be_fulfilled
        expect(snapshot.status).to be_nil
        expect(snapshot.value).to eq(write.value)
        expect(snapshot.summary).to eq("#{assignment.name} updated its value to be empty.")
        expect(snapshot.xid).to eq(write.txid)
        expect(snapshot.details_json).to eq({value: write.value, txid: write.txid}.to_json)
      end
    end

    context "when the adapter is a Bitcoin oracle" do
      let(:oracle) { factory_create :custom_expectation }
      let(:assignment) { factory_create :assignment, adapter: oracle }
      let(:snapshot) { assignment.snapshots.build }

      it "creates an API result record" do
        expect {
          snapshot.save
        }.to change {
          oracle.reload.api_results.count
        }.by(+1)
      end

      it "sets all the values off of the oracle write record" do
        snapshot.save
        result = ApiResult.last

        expect(snapshot).to be_fulfilled
        expect(snapshot.status).to be_nil
        expect(snapshot.value).to eq(result.parsed_value)
        expect(snapshot.summary).to eq("#{assignment.name} parsed a null value.")
        expect(snapshot.xid).to be_present
        expect(snapshot.details_json).to eq({value: result.parsed_value}.to_json)
      end
    end
  end

  describe "#current_adapter_snapshot" do
    let(:snapshot) { factory_create :assignment_snapshot }
    let!(:adapter_snapshot1) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }
    let!(:adapter_snapshot2) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }
    let!(:adapter_snapshot3) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }

    before do
      snapshot.update_attributes(adapter_index: adapter_snapshot2.index)
    end

    it "returns the adapter snapshot that matches the index" do
      expect(snapshot.current_adapter_snapshot).to eq(adapter_snapshot2)
    end
  end

  describe "#current_adapter_snapshot" do
    let(:snapshot) { factory_create :assignment_snapshot }
    let!(:adapter_snapshot1) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }
    let!(:adapter_snapshot2) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }
    let!(:adapter_snapshot3) { factory_create :adapter_snapshot, assignment_snapshot: snapshot }

    before do
      snapshot.update_attributes(adapter_index: adapter_snapshot1.index)
    end

    it "returns the next adapter snapshot above the current index" do
      expect(snapshot.next_adapter_snapshot).to eq(adapter_snapshot2)
    end
  end

  describe "#adapter_response" do
    let(:snapshot) { factory_create :assignment_snapshot }
    let(:handler) { instance_double AssignmentSnapshotHandler }
    let(:adapter_snapshot) { factory_create :adapter_snapshot }

    before do
      allow(AssignmentSnapshotHandler).to receive(:new)
        .with(snapshot)
        .and_return(handler)
    end

    it "passes the response on to a handler" do
      expect(handler).to receive(:adapter_response)
        .with(adapter_snapshot)

      snapshot.adapter_response(adapter_snapshot)
    end
  end

end
